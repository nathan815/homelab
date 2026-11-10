#!/usr/bin/env python3
"""Minimal ACP client (stdlib only). Newline-delimited JSON-RPC 2.0 over a child's stdio.
Usage: client.py [--cmd "docker exec -i -u hermes acpspike-hermes hermes acp"] [--raw]
Also importable: AcpClient(cmd_argv).
"""
import json, subprocess, sys, threading, queue, time, shlex, argparse

class AcpClient:
    def __init__(self, argv, raw=False, on_permission=None):
        self.p = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)
        self.raw, self.on_permission = raw, on_permission
        self.next_id, self.pending, self.notifs = 1, {}, []
        self.lock = threading.Lock()
        threading.Thread(target=self._read, daemon=True).start()
        threading.Thread(target=self._err, daemon=True).start()

    def _err(self):
        for l in self.p.stderr: sys.stderr.write("  [agent stderr] " + l)

    def _send(self, obj):
        line = json.dumps(obj)
        if self.raw: print(">>", line, flush=True)
        with self.lock:
            self.p.stdin.write(line + "\n"); self.p.stdin.flush()

    def _read(self):
        for line in self.p.stdout:
            line = line.strip()
            if not line: continue
            if self.raw: print("<<", line, flush=True)
            m = json.loads(line)
            if "method" in m and "id" in m:             # agent -> client request
                threading.Thread(target=self._handle_request, args=(m,), daemon=True).start()
            elif "method" in m:                          # notification
                self.notifs.append(m); self._show(m)
            elif m.get("id") in self.pending:
                q = self.pending.pop(m["id"]); q.put(m)

    def _handle_request(self, m):
        if m["method"] == "session/request_permission":
            opts = m["params"]["options"]
            print("  [PERMISSION REQUEST] tool_call=%s options=%s" % (json.dumps(m["params"]["toolCall"])[:300], [(o["optionId"], o["kind"]) for o in opts]))
            choice = self.on_permission(m["params"]) if self.on_permission else opts[0]["optionId"]
            res = {"outcome": {"outcome": "selected", "optionId": choice}} if choice else {"outcome": {"outcome": "cancelled"}}
            print("  [PERMISSION ANSWER]", res)
            self._send({"jsonrpc": "2.0", "id": m["id"], "result": res})
        else:
            self._send({"jsonrpc": "2.0", "id": m["id"], "error": {"code": -32601, "message": "not supported"}})

    def _show(self, m):
        if m["method"] != "session/update": print("  [notif]", m["method"]); return
        u = m["params"]["update"]; k = u.get("sessionUpdate")
        if k in ("agent_message_chunk", "agent_thought_chunk"):
            print("  [%s] %r" % (k, u.get("content", {}).get("text")))
        elif k in ("tool_call", "tool_call_update"):
            print("  [%s] id=%s status=%s title=%r kind=%s out=%s" % (k, u.get("toolCallId"), u.get("status"), u.get("title"), u.get("kind"), json.dumps(u.get("rawOutput") or u.get("content"))[:200]))
        else:
            print("  [%s] %s" % (k, json.dumps(u)[:200]))

    def request_async(self, method, params):
        i = self.next_id; self.next_id += 1
        q = queue.Queue(); self.pending[i] = q
        self._send({"jsonrpc": "2.0", "id": i, "method": method, "params": params})
        return q

    def request(self, method, params, timeout=120):
        r = self.request_async(method, params).get(timeout=timeout)
        if "error" in r: raise RuntimeError("%s -> %s" % (method, r["error"]))
        return r["result"]

    def notify(self, method, params):
        self._send({"jsonrpc": "2.0", "method": method, "params": params})

    def close(self):
        try: self.p.stdin.close()
        except Exception: pass
        try: self.p.wait(5)
        except Exception: self.p.kill()

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cmd", default="docker exec -i -u hermes acpspike-hermes hermes acp")
    ap.add_argument("--raw", action="store_true", help="print raw JSON lines")
    ap.add_argument("--cwd", default="/tmp")
    a = ap.parse_args()
    c = AcpClient(shlex.split(a.cmd), raw=a.raw, on_permission=lambda p: "allow_once")

    print("== initialize"); r = c.request("initialize", {"protocolVersion": 1, "clientCapabilities": {"fs": {"readTextFile": False, "writeTextFile": False}}, "clientInfo": {"name": "acpspike", "version": "0"}})
    print(json.dumps(r, indent=1)[:1500])
    am = [m["id"] for m in r.get("authMethods", [])]
    print("== authenticate", am[0] if am else None)
    if am: print(c.request("authenticate", {"methodId": am[0]}))
    print("== session/new"); s = c.request("session/new", {"cwd": a.cwd, "mcpServers": []}); sid = s["sessionId"]; print(json.dumps(s)[:600])

    print("== prompt 1 (plain text)")
    print(" result:", c.request("session/prompt", {"sessionId": sid, "prompt": [{"type": "text", "text": "say hello"}]}))

    print("== prompt 2 (tool call: echo hi)")
    print(" result:", c.request("session/prompt", {"sessionId": sid, "prompt": [{"type": "text", "text": "TOOL:echo hi"}]}))

    print("== prompt 3 (dangerous cmd -> permission, ALLOW once)")
    print(" result:", c.request("session/prompt", {"sessionId": sid, "prompt": [{"type": "text", "text": "DANGER"}]}))

    print("== prompt 4 (dangerous cmd -> permission, DENY)")
    c.on_permission = lambda p: "deny"
    print(" result:", c.request("session/prompt", {"sessionId": sid, "prompt": [{"type": "text", "text": "DANGER"}]}))

    print("== prompt 5 (SLOW stream, cancel after ~2.5s)")
    q = c.request_async("session/prompt", {"sessionId": sid, "prompt": [{"type": "text", "text": "SLOW"}]})
    time.sleep(2.5); t0 = time.time()
    c.notify("session/cancel", {"sessionId": sid})
    r = q.get(timeout=60); print(" result:", r.get("result") or r, "(%.2fs after cancel)" % (time.time() - t0))

    print("== session/list"); print(json.dumps(c.request("session/list", {"cwd": a.cwd}))[:500])
    c.close()

if __name__ == "__main__": main()

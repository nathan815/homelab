#!/usr/bin/env python3
"""Mock OpenAI-compatible chat-completions server (stdlib only, SSE streaming).
Triggers (looked up in the last user message):
  TOOL:<cmd>   -> assistant calls the `terminal` tool with command <cmd>
  DANGER       -> assistant calls terminal with `rm -rf /tmp/acpspike-victim` (dangerous pattern -> approval)
  SLOW         -> streams ~60 words, 0.5s apart (for cancel test)
  else         -> short text reply
After a tool result (last msg role=tool) it replies "Tool finished: <result>".
"""
import json, sys, time, uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

def log(*a): print(*a, file=sys.stderr, flush=True)

class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass
    def do_GET(self):
        log("GET", self.path)
        body = json.dumps({"object": "list", "data": [{"id": "mock-model", "object": "model"}]}).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0)); req = json.loads(self.rfile.read(n) or b"{}")
        msgs = req.get("messages", [])
        tools = [t["function"]["name"] for t in req.get("tools", [])]
        last = msgs[-1] if msgs else {}
        log("POST", self.path, "stream=%s" % req.get("stream"), "nmsgs=%d" % len(msgs), "last_role=%s" % last.get("role"), "ntools=%d" % len(tools))
        text, call = "Hello from the mock LLM.", None
        content = last.get("content") or ""
        if isinstance(content, list): content = " ".join(p.get("text", "") for p in content if isinstance(p, dict))
        if last.get("role") == "tool":
            text = "Tool finished: " + str(content)[:200]
        elif "TOOL:" in content:
            call = ("terminal", {"command": content.split("TOOL:", 1)[1].strip()})
        elif "DANGER" in content:
            call = ("terminal", {"command": "rm -rf /tmp/acpspike-victim"})
        elif "SLOW" in content:
            text = " ".join("word%d" % i for i in range(60))
        cid = "chatcmpl-" + uuid.uuid4().hex[:8]
        def chunk(delta, fin=None):
            return {"id": cid, "object": "chat.completion.chunk", "created": int(time.time()), "model": "mock-model",
                    "choices": [{"index": 0, "delta": delta, "finish_reason": fin}]}
        if not req.get("stream"):
            msg = {"role": "assistant", "content": None if call else text}
            if call: msg["tool_calls"] = [{"id": "call_1", "type": "function", "function": {"name": call[0], "arguments": json.dumps(call[1])}}]
            body = json.dumps({"id": cid, "object": "chat.completion", "created": int(time.time()), "model": "mock-model",
                "choices": [{"index": 0, "message": msg, "finish_reason": "tool_calls" if call else "stop"}],
                "usage": {"prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15}}).encode()
            self.send_response(200); self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body); return
        self.send_response(200); self.send_header("Content-Type", "text/event-stream")
        self.send_header("Transfer-Encoding", "chunked"); self.end_headers()
        def send(obj):
            data = ("data: " + (obj if isinstance(obj, str) else json.dumps(obj)) + "\n\n").encode()
            self.wfile.write(b"%x\r\n" % len(data) + data + b"\r\n"); self.wfile.flush()
        try:
            send(chunk({"role": "assistant", "content": ""}))
            if call:
                send(chunk({"tool_calls": [{"index": 0, "id": "call_" + uuid.uuid4().hex[:6], "type": "function",
                            "function": {"name": call[0], "arguments": json.dumps(call[1])}}]}))
                send(chunk({}, "tool_calls"))
            else:
                slow = "SLOW" in content
                for w in text.split(" "):
                    send(chunk({"content": w + " "}))
                    if slow: time.sleep(0.5)
                send(chunk({}, "stop"))
            send("[DONE]"); self.wfile.write(b"0\r\n\r\n"); self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            log("client disconnected mid-stream")

ThreadingHTTPServer(("0.0.0.0", 8080), H).serve_forever()

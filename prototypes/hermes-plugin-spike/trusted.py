"""Trusted-side server (stdlib). LISTENS on a unix socket or TCP; Hermes dials in.
Usage: trusted.py --listen unix:///sock/trusted.sock|tcp://0.0.0.0:9000 --script scenario.txt
Scenario lines: `send <text>` | `interrupt` | `wait-done [s]` | `sleep <s>` | `wait-type <type>`
Approval requests are auto-answered per --approve (once|deny|none)."""
import argparse, json, os, socket, threading, time, queue

ap = argparse.ArgumentParser()
ap.add_argument("--listen", required=True)
ap.add_argument("--script", default="")
ap.add_argument("--approve", default="once")
ap.add_argument("-v", action="store_true")
ap.add_argument("--raw", action="store_true", help="also print every received line verbatim as RAW <json>")
a = ap.parse_args()

if a.listen.startswith("unix://"):
    p = a.listen[7:]
    if os.path.exists(p):
        os.unlink(p)
    srv = socket.socket(socket.AF_UNIX)
    srv.bind(p)
    os.chmod(p, 0o666)
else:
    h, _, port = a.listen[len("tcp://"):].rpartition(":")
    srv = socket.socket()
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((h, int(port)))
srv.listen(1)
T0 = time.time()


def log(s):
    print(f"[{time.time()-T0:6.2f}] {s}", flush=True)


log(f"listening {a.listen}")
events = queue.Queue()


def reader(conn, f, wlock):
    for line in f:
        if a.raw:
            print("RAW " + line.rstrip("\n"), flush=True)
        m = json.loads(line)
        t = m.get("type")
        events.put(m)
        if t == "typing" and not a.v:
            continue
        if t == "assistant_delta":
            log(f"<- delta  {m['text']!r}")
        elif t == "assistant_text":
            log(f"<- TEXT   {m['text']!r}  meta={m.get('metadata')}")
        elif t == "assistant_edit":
            log(f"<- EDIT   delta={m.get('delta')!r} final={m.get('finalize')} (full={m['text']!r})")
        elif t == "tool_activity":
            log(f"<- TOOL   {m['tool']} {m.get('args')}")
        elif t == "approval_request":
            log(f"<- APPROVAL id={m['approval_id']} cmd={m['command']!r} choices={m['choices']} desc={m['description']!r}")
            if a.approve != "none":
                time.sleep(0.5)
                with wlock:
                    conn.sendall((json.dumps({"type": "approval_response", "approval_id": m["approval_id"],
                                              "choice": a.approve}) + "\n").encode())
                log(f"-> approval_response {a.approve}")
        elif t == "done":
            log(f"<- DONE   outcome={m.get('outcome')}")
        elif t == "tool_start":
            log(f"<- TOOL>  {m['tool']} {m['args']} id={m['tool_call_id']}")
        elif t == "tool_end":
            log(f"<- TOOL<  {m['tool']} result={m['result']}")
        elif t == "stopped":
            log(f"<- STOPPED reason={m.get('reason')}")
        elif t == "hook":
            log(f"<- HOOK   {m['hook']} {json.dumps(m['data'])[:300]}")
        else:
            log(f"<- {json.dumps(m)}")
    log("peer closed")
    events.put({"type": "_closed"})


def wait_type(ty, timeout=60):
    end = time.time() + timeout
    while time.time() < end:
        try:
            m = events.get(timeout=1)
        except queue.Empty:
            continue
        if m.get("type") == ty:
            return m
    log(f"!! timeout waiting for {ty}")
    return None


conn, _ = srv.accept()
log("hermes connected (it dialled us)")
f = conn.makefile("r", encoding="utf-8")
wlock = threading.Lock()
threading.Thread(target=reader, args=(conn, f, wlock), daemon=True).start()


def send(o):
    with wlock:
        conn.sendall((json.dumps(o) + "\n").encode())


wait_type("hello", 300)
n = 0
for raw in (open(a.script) if a.script else []):
    raw = raw.strip()
    if not raw or raw.startswith("#"):
        continue
    cmd, _, arg = raw.partition(" ")
    if cmd == "send":
        n += 1
        log(f"-> user_message {arg!r}")
        send({"type": "user_message", "chat_id": "main", "user_id": "trusted-user", "id": f"u{n}", "text": arg})
    elif cmd == "interrupt":
        log("-> interrupt")
        send({"type": "interrupt", "chat_id": "main"})
    elif cmd == "wait-done":
        wait_type("done", float(arg or 90))
    elif cmd == "wait-type":
        wait_type(arg)
    elif cmd == "sleep":
        time.sleep(float(arg))
log("script finished")
time.sleep(2)

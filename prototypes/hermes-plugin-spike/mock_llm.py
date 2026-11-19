"""Mock OpenAI-compatible /v1/chat/completions (stdlib). Streams SSE.
Triggers (in last user message): TOOL -> terminal `echo hi`; DANGER -> terminal `rm -rf /tmp/plugspike-danger`;
SLOW -> 40 deltas at 0.5s; otherwise a short plain reply. After a tool result -> summary reply."""
import json, sys, time, uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def text_of(m):
    c = m.get("content")
    if isinstance(c, list):
        return " ".join(p.get("text", "") for p in c if isinstance(p, dict))
    return c or ""


def plan(messages):
    last = messages[-1] if messages else {}
    if last.get("role") == "tool":
        return ("text", ["Tool ", "finished. ", "Output ", "was: ", text_of(last)[:200]], 0.05)
    user = next((text_of(m) for m in reversed(messages) if m.get("role") == "user"), "")
    if "DANGER" in user:
        return ("tool", ["terminal", {"command": "rm -rf /tmp/plugspike-danger"}], 0)
    if "TOOL" in user:
        return ("tool", ["terminal", {"command": "echo hi"}], 0)
    if "SLOW" in user:
        return ("text", [f"tok{i} " for i in range(40)], 0.5)
    return ("text", ["Hello ", "from ", "the ", "mock ", "LLM. ", "You ", "said: ", user[:80]], 0.15)


class H(BaseHTTPRequestHandler):
    def log_message(self, f, *a):
        sys.stderr.write("mock: " + f % a + "\n")

    def _json(self, o, code=200):
        b = json.dumps(o).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        if self.path.endswith("/models"):
            return self._json({"object": "list", "data": [{"id": "mock-model", "object": "model", "context_length": 100000}]})
        self._json({"ok": True})

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
        kind, parts, delay = plan(body.get("messages", []))
        sys.stderr.write(f"mock: req stream={body.get('stream')} plan={kind} last={body['messages'][-1].get('role')} auth={self.headers.get('Authorization')}\n")
        cid, now = "chatcmpl-" + uuid.uuid4().hex[:8], int(time.time())

        def chunk(delta, fin=None):
            return {"id": cid, "object": "chat.completion.chunk", "created": now, "model": "mock-model",
                    "choices": [{"index": 0, "delta": delta, "finish_reason": fin}]}

        if kind == "tool":
            msg = {"role": "assistant", "content": None, "tool_calls": [{"id": "call_" + uuid.uuid4().hex[:6], "type": "function",
                   "function": {"name": parts[0], "arguments": json.dumps(parts[1])}}]}
            fin = "tool_calls"
        else:
            msg = {"role": "assistant", "content": "".join(parts)}
            fin = "stop"
        if not body.get("stream"):
            return self._json({"id": cid, "object": "chat.completion", "created": now, "model": "mock-model",
                               "choices": [{"index": 0, "message": msg, "finish_reason": fin}],
                               "usage": {"prompt_tokens": 10, "completion_tokens": 10, "total_tokens": 20}})
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()

        def w(o):
            self.wfile.write(b"data: " + (json.dumps(o) if o != "[DONE]" else o).encode() + b"\n\n")
            self.wfile.flush()

        try:
            w(chunk({"role": "assistant", "content": ""}))
            if kind == "tool":
                tc = msg["tool_calls"][0]
                w(chunk({"tool_calls": [{"index": 0, "id": tc["id"], "type": "function",
                                         "function": {"name": tc["function"]["name"], "arguments": ""}}]}))
                w(chunk({"tool_calls": [{"index": 0, "function": {"arguments": tc["function"]["arguments"]}}]}))
            else:
                for p in parts:
                    w(chunk({"content": p}))
                    time.sleep(delay)
            w(chunk({}, fin))
            w({"id": cid, "object": "chat.completion.chunk", "created": now, "model": "mock-model", "choices": [],
               "usage": {"prompt_tokens": 10, "completion_tokens": 10, "total_tokens": 20}})
            w("[DONE]")
        except (BrokenPipeError, ConnectionResetError):
            sys.stderr.write("mock: client disconnected mid-stream (interrupt)\n")


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", 8000), H).serve_forever()

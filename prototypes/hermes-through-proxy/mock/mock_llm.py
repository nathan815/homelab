#!/usr/bin/env python3
"""Mock on the EGRESS side. HTTPS :443 (self-signed; proxy runs ssl_insecure). One server, behaviour by Host header:
  llm.mock.test       OpenAI-compatible /v1/chat/completions (stream + non-stream) and /v1/models
  firecrawl.mock.test minimal Firecrawl-ish scrape/search JSON (to see which host web_extract talks to)
  search.mock.test    SearXNG-ish /search?format=json
Every request's method, host, path and Authorization header is appended to /logs/received.jsonl.
Prompt triggers (last user message): BROWSE <url> | EXTRACT <url> | SEARCH <q> | TERM <cmd> ; else text.
After a tool result: replies 'Tool finished: <first 300 chars>'. SLOWLLM in prompt -> sleep 20s before replying.
"""
import json, ssl, sys, time, uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LOG = "/logs/received.jsonl"

def rec(h, body=b""):
    r = dict(t=time.time(), method=h.command, host=h.headers.get("Host"), path=h.path,
             auth=h.headers.get("Authorization"), ua=h.headers.get("User-Agent"), blen=len(body))
    open(LOG, "a").write(json.dumps(r) + "\n"); print(json.dumps(r), file=sys.stderr, flush=True)

def tool_call(text):
    for key, name, arg in (("BROWSE ", "browser_navigate", "url"), ("EXTRACT ", "web_extract", None),
                           ("SEARCH ", "web_search", "query"), ("TERM ", "terminal", "command")):
        if key in text:
            v = text.split(key, 1)[1].strip().split("\n")[0]
            if name == "web_extract":
                return name, {"urls": [v]}
            return name, {arg: v}
    return None

class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass
    def _json(self, obj, code=200):
        b = json.dumps(obj).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_GET(self):
        rec(self)
        host = (self.headers.get("Host") or "").split(":")[0]
        if host.startswith("search"):
            return self._json({"results": [{"title": "Example Domain", "url": "https://example.com/", "content": "mock hit"}]})
        return self._json({"object": "list", "data": [{"id": "mock-model", "object": "model"}]})
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0)); raw = self.rfile.read(n) if n else b""
        rec(self, raw)
        host = (self.headers.get("Host") or "").split(":")[0]
        req = json.loads(raw or b"{}")
        if host.startswith("firecrawl"):
            return self._json({"success": True, "data": {"markdown": "# mock scrape", "metadata": {"sourceURL": req.get("url")}}})
        msgs = req.get("messages", []); last = msgs[-1] if msgs else {}
        content = last.get("content") or ""
        if isinstance(content, list):
            content = " ".join(p.get("text", "") for p in content if isinstance(p, dict))
        call, text = None, "Hello from the mock LLM."
        if last.get("role") == "tool":
            text = "Tool finished: " + str(content)[:300]
        else:
            if "SLOWLLM" in content: time.sleep(20)
            call = tool_call(content)
        cid = "chatcmpl-" + uuid.uuid4().hex[:8]
        def chunk(delta, fin=None):
            return {"id": cid, "object": "chat.completion.chunk", "created": int(time.time()), "model": "mock-model",
                    "choices": [{"index": 0, "delta": delta, "finish_reason": fin}]}
        if not req.get("stream"):
            msg = {"role": "assistant", "content": None if call else text}
            if call: msg["tool_calls"] = [{"id": "call_1", "type": "function", "function": {"name": call[0], "arguments": json.dumps(call[1])}}]
            return self._json({"id": cid, "object": "chat.completion", "created": int(time.time()), "model": "mock-model",
                "choices": [{"index": 0, "message": msg, "finish_reason": "tool_calls" if call else "stop"}],
                "usage": {"prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15}})
        self.send_response(200); self.send_header("Content-Type", "text/event-stream"); self.send_header("Transfer-Encoding", "chunked"); self.end_headers()
        def send(obj):
            d = ("data: " + (obj if isinstance(obj, str) else json.dumps(obj)) + "\n\n").encode()
            self.wfile.write(b"%x\r\n" % len(d) + d + b"\r\n"); self.wfile.flush()
        send(chunk({"role": "assistant", "content": ""}))
        if call:
            send(chunk({"tool_calls": [{"index": 0, "id": "call_" + uuid.uuid4().hex[:6], "type": "function",
                        "function": {"name": call[0], "arguments": json.dumps(call[1])}}]})); send(chunk({}, "tool_calls"))
        else:
            for w in text.split(" "): send(chunk({"content": w + " "}))
            send(chunk({}, "stop"))
        send("[DONE]"); self.wfile.write(b"0\r\n\r\n"); self.wfile.flush()

ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); ctx.load_cert_chain("/certs/mock.crt", "/certs/mock.key")
srv = ThreadingHTTPServer(("0.0.0.0", 443), H); srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
srv.serve_forever()

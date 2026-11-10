"""Egress approval proxy: mitmproxy addon + approval API (aiohttp) in one process.

Per request: SSRF guard -> rules store -> otherwise HOLD the flow and ask the user.
The approval API listens ONLY on APPROVAL_BIND (the proxy's control-network IP),
never on the sandbox-facing interface.
"""
import asyncio
import ipaddress
import json
import os
import re
import shutil
import socket
import time
import uuid
from pathlib import Path
from urllib.parse import urlsplit

from aiohttp import web
from mitmproxy import ctx, http
from mitmproxy.certs import CertStore

DATA = Path(os.environ.get("DATA_DIR", "/data"))
TIMEOUT = float(os.environ.get("APPROVAL_TIMEOUT", "120"))
BIND = os.environ.get("APPROVAL_BIND", "127.0.0.1")
PORT = int(os.environ.get("APPROVAL_PORT", "8081"))
ALLOWED_CONNECT_PORTS = {80, 443}
READ_METHODS = {"GET", "HEAD"}
BLOCKED_NAMES = {"localhost", "proxy", "host.docker.internal", "gateway.docker.internal"}


# --------------------------------------------------------------------------- redaction
SECRET_RES = [
    re.compile(r"(?i)\b(authorization|password|passwd|secret|token|api[_-]?key|access[_-]?key)(\"?\s*[:=]\s*\"?)([^\s\"&,}]+)"),
    re.compile(r"(?i)\bBearer\s+\S+"),
    re.compile(r"\b(sk-[A-Za-z0-9_-]{16,}|gh[pousr]_[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}|xox[baprs]-[A-Za-z0-9-]{10,})"),
    re.compile(r"[A-Za-z0-9+/_-]{40,}={0,2}"),  # long opaque blobs
]


def redact(text: str) -> str:
    text = SECRET_RES[0].sub(lambda m: f"{m[1]}{m[2]}[REDACTED]", text)
    for rx in SECRET_RES[1:]:
        text = rx.sub("[REDACTED]", text)
    return text


def body_preview(body: bytes) -> str:
    if not body:
        return ""
    head = body[:4000]
    if sum(b < 9 or 13 < b < 32 for b in head) > len(head) * 0.1:
        return f"<binary, {len(body)} bytes>"
    return redact(head.decode("utf-8", "replace"))[:200]


# --------------------------------------------------------------------------- rules store
def origin_of(scheme: str, host: str, port: int) -> str:
    default = {"http": 80, "https": 443}.get(scheme)
    return f"{scheme}://{host.lower()}" + ("" if port == default else f":{port}")


class Rules:
    """rules.json: [{id, origin, methods, path_prefix, action, created, note}]"""

    def __init__(self, path: Path):
        self.path = path
        self.rules = json.loads(path.read_text()) if path.exists() else []

    def _save(self):
        tmp = self.path.with_suffix(".tmp")
        tmp.write_text(json.dumps(self.rules, indent=2))
        tmp.replace(self.path)

    def add(self, origin, methods, path_prefix=None, action="allow", note=""):
        for r in self.rules:  # idempotent
            if (r["origin"], r["methods"], r["path_prefix"], r["action"]) == (origin, methods, path_prefix, action):
                return r
        r = dict(id=uuid.uuid4().hex[:8], origin=origin, methods=methods, path_prefix=path_prefix,
                 action=action, created=time.time(), note=note)
        self.rules.append(r)
        self._save()
        return r

    def delete(self, rid) -> bool:
        n = len(self.rules)
        self.rules = [r for r in self.rules if r["id"] != rid]
        self._save()
        return len(self.rules) != n

    def match(self, origin, method, path):
        hits = [r for r in self.rules if r["origin"] == origin and method in r["methods"]
                and (not r["path_prefix"] or path.startswith(r["path_prefix"]))]
        hits.sort(key=lambda r: r["action"] != "deny")  # deny wins
        return hits[0] if hits else None


# --------------------------------------------------------------------------- state
rules: Rules
pending: dict[str, dict] = {}
subscribers: set[asyncio.Queue] = set()
LOG = DATA / "decisions.jsonl"


def publish(event: str, data: dict):
    for q in list(subscribers):
        q.put_nowait((event, data))


def log_decision(flow_req, decision: str, source: str):
    rec = dict(time=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), method=flow_req.method,
               url=redact(flow_req.url), decision=decision, source=source)
    with LOG.open("a") as f:
        f.write(json.dumps(rec) + "\n")
    ctx.log.info("DECISION " + json.dumps(rec))


def card(req: http.Request) -> dict:
    url = redact(req.url)
    if req.method in READ_METHODS:
        kind, text = "browse", f"Allow the agent to browse {url}?"
    else:
        kind, text = "send_data", f"Allow the agent to send data to {url}? ({req.method})"
    body = req.raw_content or b""
    return dict(id=uuid.uuid4().hex[:8], kind=kind, text=text, method=req.method, url=url,
                body_size=len(body), body_preview=body_preview(body) if kind == "send_data" else "",
                created=time.time(), expires_at=time.time() + TIMEOUT)


def refuse(flow: http.HTTPFlow, why: str, status=403):
    flow.response = http.Response.make(status, f"Blocked by the egress approval proxy: {why}\n",
                                       {"Content-Type": "text/plain; charset=utf-8", "X-Egress-Decision": "denied"})


async def guard(host: str):
    """Refuse internal destinations (the proxy can reach networks the sandbox cannot)."""
    if host.lower().rstrip(".") in BLOCKED_NAMES:
        return f"{host} is an internal name"
    try:
        infos = await asyncio.get_running_loop().getaddrinfo(host, None)
    except socket.gaierror:
        return None  # unresolvable: let the upstream connection fail normally
    for info in infos:
        ip = ipaddress.ip_address(info[4][0].split("%")[0])
        if not ip.is_global:
            return f"{host} resolves to non-public address {ip}"
    return None


# --------------------------------------------------------------------------- the addon
class Egress:
    def http_connect(self, flow: http.HTTPFlow):
        if flow.request.port not in ALLOWED_CONNECT_PORTS:
            refuse(flow, f"tunnels to port {flow.request.port} are not permitted (only 80/443).")
            log_decision(flow.request, "deny", "connect-port")

    async def request(self, flow: http.HTTPFlow):
        if flow.response:  # already refused
            return
        req = flow.request
        origin = origin_of(req.scheme, req.host, req.port)

        why = await guard(req.host)
        if why:
            refuse(flow, f"destination not allowed ({why}). This is a hard rule, not a user decision.")
            return log_decision(req, "deny", "guard")

        rule = rules.match(origin, req.method, req.path)
        if rule:
            if rule["action"] == "deny":
                refuse(flow, f"a standing rule ({rule['id']}) denies {req.method} {origin}.")
                return log_decision(req, "deny", f"rule:{rule['id']}")
            return log_decision(req, "allow", f"rule:{rule['id']}")

        ap = card(req)
        fut = asyncio.get_running_loop().create_future()
        pending[ap["id"]] = dict(card=ap, fut=fut, req=req)
        publish("pending", ap)
        try:
            decision, source = await asyncio.wait_for(fut, TIMEOUT)
        except asyncio.TimeoutError:
            decision, source = "timeout", "timeout"
        except asyncio.CancelledError:  # agent gave up / disconnected while held
            log_decision(req, "abandoned", "client-disconnect")
            raise
        finally:
            pending.pop(ap["id"], None)
            publish("resolved", {"id": ap["id"]})

        if decision in ("allow_once", "always_allow"):
            return log_decision(req, "allow", source)
        if decision == "timeout":
            refuse(flow, f"the user did not respond within {int(TIMEOUT)}s, so {req.method} {req.url} was denied "
                         "by default. You may ask the user to approve it and retry.")
        else:
            refuse(flow, f"the user denied the agent's request to {req.method} {req.url}. "
                         "Do not retry it; use another approach or ask the user.")
        log_decision(req, "deny", source)

    async def running(self):
        # Publish ONLY the public CA cert for the sandbox.
        confdir = Path(ctx.options.confdir).expanduser()
        CertStore.from_store(confdir, "mitmproxy", ctx.options.key_size)  # creates the CA on first start
        src = confdir / "mitmproxy-ca-cert.pem"
        shutil.copy(src, "/ca-public/mitmproxy-ca-cert.pem")
        runner = web.AppRunner(make_app())
        await runner.setup()
        await web.TCPSite(runner, BIND, PORT).start()
        ctx.log.info(f"approval API on http://{BIND}:{PORT}  (timeout {TIMEOUT}s)")


# --------------------------------------------------------------------------- approval API
def make_app() -> web.Application:
    async def index(_):
        return web.Response(text=Path("/addon/ui.html").read_text(), content_type="text/html")

    async def list_pending(_):
        return web.json_response([p["card"] for p in pending.values()])

    async def decide(request):
        p = pending.get(request.match_info["id"])
        if not p:
            return web.json_response({"error": "not pending (decided, expired or abandoned)"}, status=404)
        decision = (await request.json()).get("decision")
        if decision not in ("allow_once", "always_allow", "deny"):
            return web.json_response({"error": "decision must be allow_once|always_allow|deny"}, status=400)
        req, source, rule = p["req"], f"user:{decision}", None
        if decision == "always_allow":
            origin = origin_of(req.scheme, req.host, req.port)
            if req.method in READ_METHODS:  # default scope: scheme+host, reads only
                rule = rules.add(origin, ["GET", "HEAD"], note="always allow (reads)")
            else:  # writes: only this method + exact path
                rule = rules.add(origin, [req.method], req.path.split("?")[0], note="always allow (this write)")
            source = f"user:always_allow:{rule['id']}"
        if not p["fut"].done():
            p["fut"].set_result((decision, source))
        return web.json_response({"ok": True, "rule": rule})

    async def list_rules(_):
        return web.json_response(rules.rules)

    async def delete_rule(request):
        ok = rules.delete(request.match_info["id"])
        return web.json_response({"deleted": ok}, status=200 if ok else 404)

    async def tail_log(request):
        n = int(request.query.get("n", "50"))
        lines = LOG.read_text().splitlines()[-n:] if LOG.exists() else []
        return web.json_response([json.loads(line) for line in lines])

    async def events(request):
        resp = web.StreamResponse(headers={"Content-Type": "text/event-stream", "Cache-Control": "no-cache"})
        await resp.prepare(request)
        q: asyncio.Queue = asyncio.Queue()
        subscribers.add(q)
        try:
            await resp.write(b": hello\n\n")
            while True:
                try:
                    event, data = await asyncio.wait_for(q.get(), 15)
                    await resp.write(f"event: {event}\ndata: {json.dumps(data)}\n\n".encode())
                except asyncio.TimeoutError:
                    await resp.write(b": keepalive\n\n")
        except (ConnectionResetError, asyncio.CancelledError):
            pass
        finally:
            subscribers.discard(q)
        return resp

    app = web.Application()
    app.add_routes([
        web.get("/", index), web.get("/healthz", lambda _: web.Response(text="ok")),
        web.get("/approvals", list_pending), web.post("/approvals/{id}/decision", decide),
        web.get("/rules", list_rules), web.delete("/rules/{id}", delete_rule),
        web.get("/log", tail_log), web.get("/events", events),
    ])
    return app


DATA.mkdir(parents=True, exist_ok=True)
rules = Rules(DATA / "rules.json")
addons = [Egress()]

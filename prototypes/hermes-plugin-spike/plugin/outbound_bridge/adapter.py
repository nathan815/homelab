"""outbound_bridge: Hermes platform adapter that DIALS OUT (no listener).

Wire protocol: newline-delimited JSON, one object per line, "type" discriminates.
  trusted -> hermes: user_message, interrupt, approval_response, ping
  hermes -> trusted: hello, assistant_text, assistant_edit (with derived delta),
                     approval_request, typing, done
"""
from __future__ import annotations

import asyncio
import contextlib
import json
import logging
import threading
import time
import uuid
from typing import Any, Dict, Optional

from gateway.config import Platform
from gateway.platforms._shared import extra_or_secret
from gateway.platforms.base import BasePlatformAdapter, ExecApprovalPrompt, SendResult
from gateway.platforms.event import MessageEvent, MessageType

logger = logging.getLogger(__name__)
PLATFORM = "outbound_bridge"


def _jsonable(o: Any, limit: int = 2000) -> Any:
    try:
        json.dumps(o)
        return o if not isinstance(o, str) or len(o) <= limit else o[:limit] + "...[truncated]"
    except Exception:
        return repr(o)[:limit]


_ADAPTER: Optional["OutboundBridgeAdapter"] = None   # hooks are module-level callbacks; find the adapter here


class OutboundBridgeAdapter(BasePlatformAdapter):
    MAX_MESSAGE_LENGTH = 1_000_000

    def __init__(self, config):
        super().__init__(config, Platform(PLATFORM))
        ex = config.extra or {}
        self.endpoint = str(extra_or_secret(ex, "endpoint", "OUTBOUND_BRIDGE_ENDPOINT", "")).strip()
        self.default_user = str(extra_or_secret(ex, "user_id", "OUTBOUND_BRIDGE_USER_ID", "trusted-user"))
        self._reader: Optional[asyncio.StreamReader] = None
        self._writer: Optional[asyncio.StreamWriter] = None
        self._loop: Optional[asyncio.AbstractEventLoop] = None
        self._conn_task: Optional[asyncio.Task] = None
        self._stop = False
        self._pending_approvals: Dict[str, str] = {}   # approval_id -> session_key
        self._seq = 0
        self._upstream_auth = str(extra_or_secret(ex, "upstream_auth", "OUTBOUND_BRIDGE_UPSTREAM_AUTH", "true")).lower() != "false"
        global _ADAPTER
        _ADAPTER = self
        self._last_text: Dict[str, str] = {}

    # The trusted side is the only peer and we dialled it: delegate authz upstream so the
    # gateway's allowlist / DM-pairing gate is skipped (same flag the relay + a2a adapters use).
    @property
    def authorization_is_upstream(self) -> bool:
        return self._upstream_auth

    # ---------------- connection ----------------
    async def _open(self):
        ep = self.endpoint
        if ep.startswith("unix://"):
            return await asyncio.open_unix_connection(ep[len("unix://"):])
        if ep.startswith("tcp://"):
            host, _, port = ep[len("tcp://"):].rpartition(":")
            return await asyncio.open_connection(host, int(port))
        raise ValueError(f"bad endpoint {ep!r}")

    async def connect(self, *, is_reconnect: bool = False) -> bool:
        self._loop = asyncio.get_running_loop()
        self._stop = False
        # First dial happens inline so connect() can report failure; later drops are
        # handled by the background reconnect loop below.
        try:
            self._reader, self._writer = await asyncio.wait_for(self._open(), 10)
        except Exception as e:
            logger.error("outbound_bridge: dial %s failed: %s", self.endpoint, e)
            self._set_fatal_error("dial_failed", str(e), retryable=True)
            return False
        self._send_now({"type": "hello", "platform": PLATFORM, 
                        "caps": ["delta", "tool_activity", "approval", "interrupt"]})
        self._conn_task = asyncio.create_task(self._run())
        self._mark_connected()
        return True

    async def disconnect(self) -> None:
        self._stop = True
        self._mark_disconnected()
        if self._conn_task:
            self._conn_task.cancel()
            with contextlib.suppress(BaseException):
                await self._conn_task
        await self._close()

    async def _close(self):
        w, self._writer, self._reader = self._writer, None, None
        if w:
            with contextlib.suppress(Exception):
                w.close()
                await w.wait_closed()

    async def _run(self):
        backoff = 0.5
        while not self._stop:
            try:
                if self._reader is None:
                    self._reader, self._writer = await asyncio.wait_for(self._open(), 10)
                    self._send_now({"type": "hello", "platform": PLATFORM, "reconnect": True})
                    backoff = 0.5
                    logger.info("outbound_bridge: reconnected to %s", self.endpoint)
                while True:
                    line = await self._reader.readline()
                    if not line:
                        raise ConnectionError("peer closed")
                    await self._on_line(line)
            except asyncio.CancelledError:
                raise
            except Exception as e:
                logger.warning("outbound_bridge: link down (%s); retry in %.1fs", e, backoff)
                await self._close()
                await asyncio.sleep(backoff)
                backoff = min(backoff * 2, 10)

    # ---------------- outbound (thread-safe) ----------------
    def _send_now(self, obj: dict) -> bool:
        w = self._writer
        if not w or w.is_closing():
            return False
        obj.setdefault("ts", time.time())
        w.write((json.dumps(obj, ensure_ascii=False, default=repr) + "\n").encode())
        return True

    def emit(self, obj: dict) -> None:
        """Callable from ANY thread (stream/tool hooks run on the agent worker thread)."""
        loop = self._loop
        if loop is None:
            return
        try:
            running = asyncio.get_running_loop()
        except RuntimeError:
            running = None
        if running is loop:
            self._send_now(obj)
        else:
            loop.call_soon_threadsafe(self._send_now, obj)

    # ---------------- inbound ----------------
    async def _on_line(self, line: bytes):
        try:
            m = json.loads(line)
        except Exception:
            logger.warning("outbound_bridge: bad json line %r", line[:200])
            return
        t = m.get("type")
        if t == "user_message":
            await self._inbound_text(m.get("chat_id") or "main", m.get("text") or "",
                                     m.get("user_id") or self.default_user, m.get("id"))
        elif t == "interrupt":
            # Same path as a user typing /stop (bypasses the active-session guard).
            await self._inbound_text(m.get("chat_id") or "main", "/stop",
                                     m.get("user_id") or self.default_user, m.get("id"))
        elif t == "approval_response":
            await self._on_approval(m)
        elif t == "ping":
            self._send_now({"type": "pong"})

    async def _inbound_text(self, chat_id, text, user_id, msg_id):
        source = self.build_source(chat_id=chat_id, chat_name=chat_id, chat_type="dm",
                                   user_id=user_id, user_name=user_id)
        ev = MessageEvent(text=text, message_type=MessageType.TEXT, source=source,
                          message_id=msg_id or uuid.uuid4().hex[:8])
        await self.handle_message(ev)

    async def _on_approval(self, m):
        aid = m.get("approval_id")
        choice = m.get("choice", "deny")
        sk = self._pending_approvals.pop(aid, None)
        if sk is None:
            logger.warning("outbound_bridge: unknown approval id %s", aid)
            return
        from tools.approval import resolve_gateway_approval
        n = await asyncio.to_thread(resolve_gateway_approval, sk, choice)
        logger.info("outbound_bridge: approval %s -> %s (resolved %s)", aid, choice, n)

    # ---------------- BasePlatformAdapter outputs ----------------
    def _mid(self):
        self._seq += 1
        return f"m{self._seq}"

    async def send(self, chat_id, content, reply_to=None, metadata=None) -> SendResult:
        mid = self._mid()
        self._last_text[mid] = content.rstrip(" ▉")
        ok = self._send_now({"type": "assistant_text", "chat_id": chat_id, "message_id": mid,
                             "text": content, "reply_to": reply_to,
                             "metadata": _jsonable(metadata or {})})
        return SendResult(success=ok, message_id=mid if ok else None,
                          error=None if ok else "not connected", retryable=not ok)

    async def edit_message(self, chat_id, message_id, content, *, finalize=False) -> SendResult:
        # The gateway stream consumer streams by send() once then edit_message() repeatedly with the
        # full text so far (+ a cursor glyph). Turn that into explicit deltas for the trusted side.
        cur = content.rstrip(" ▉")
        prev = self._last_text.get(message_id, "")
        delta = cur[len(prev):] if cur.startswith(prev) else None   # None => rewrite, use "text"
        self._last_text[message_id] = cur
        ok = self._send_now({"type": "assistant_edit", "chat_id": chat_id, "message_id": message_id,
                             "text": content, "delta": delta, "finalize": finalize})
        if finalize:
            self._last_text.pop(message_id, None)
        return SendResult(success=ok, message_id=message_id)

    async def send_typing(self, chat_id, metadata=None) -> None:
        self._send_now({"type": "typing", "chat_id": chat_id})

    async def get_chat_info(self, chat_id):
        return {"name": chat_id, "type": "dm"}

    async def _send_exec_approval_prompt(self, prompt: ExecApprovalPrompt) -> SendResult:
        aid = uuid.uuid4().hex[:10]
        self._pending_approvals[aid] = prompt.session_key
        ok = self._send_now({"type": "approval_request", "approval_id": aid, "chat_id": prompt.chat_id,
                             "command": prompt.command, "description": prompt.description,
                             "choices": prompt.choices, "smart_denied": prompt.smart_denied,
                             "text": prompt.text})
        if not ok:
            self._pending_approvals.pop(aid, None)
        return SendResult(success=ok, message_id=aid, error=None if ok else "not connected")

    async def on_processing_complete(self, event, outcome) -> None:
        self._send_now({"type": "done", "chat_id": event.source.chat_id,
                        "message_id": event.message_id, "outcome": getattr(outcome, "value", str(outcome))})


# ---------------- plugin lifecycle hooks (structured events from the agent loop) ----------------
_HOOKS = ("on_stream_start", "on_stream_delta", "on_stream_end", "on_interim_message", "pre_tool_call",
          "post_tool_call", "pre_approval_request", "post_approval_response", "agent_loop_stopped")


def _make_hook(name):
    """Map Hermes plugin hooks onto the wire protocol. Hooks run on the agent worker thread, so
    everything goes through adapter.emit() (call_soon_threadsafe)."""
    def cb(**kw):
        a = _ADAPTER
        if a is None:
            return
        tid = kw.get("turn_id")
        if name == "on_stream_delta":
            if kw.get("kind") == "text":
                a.emit({"type": "assistant_delta", "text": kw.get("delta", ""), "turn_id": tid})
            else:
                a.emit({"type": "assistant_delta", "kind": kw.get("kind"), "text": kw.get("delta", ""), "turn_id": tid})
        elif name == "pre_tool_call":
            a.emit({"type": "tool_start", "tool": kw.get("tool_name"), "args": _jsonable(kw.get("args")),
                    "tool_call_id": kw.get("tool_call_id"), "turn_id": tid})
        elif name == "post_tool_call":
            a.emit({"type": "tool_end", "tool": kw.get("tool_name"), "tool_call_id": kw.get("tool_call_id"),
                    "result": _jsonable(kw.get("result"), 500), "turn_id": tid})
        elif name == "agent_loop_stopped":
            a.emit({"type": "stopped", "reason": kw.get("reason"), "session_key": kw.get("session_key")})
        else:  # on_stream_start/end, on_interim_message, approval observers: pass through for the spike
            a.emit({"type": "hook", "hook": name, "data": {k: _jsonable(v, 300) for k, v in kw.items()}})
    cb.__name__ = f"ob_{name}"
    return cb


# ---------------- module hooks ----------------
def check_requirements() -> bool:
    return True  # stdlib only


def _endpoint(config) -> str:
    return str(extra_or_secret((getattr(config, "extra", None) or {}), "endpoint", "OUTBOUND_BRIDGE_ENDPOINT", "")).strip()


def validate_config(config) -> bool:
    return bool(_endpoint(config))


def _env_enablement() -> dict | None:
    ep = str(extra_or_secret({}, "endpoint", "OUTBOUND_BRIDGE_ENDPOINT", "")).strip()
    return {"endpoint": ep} if ep else None


def register(ctx):
    kwargs = dict(
        name=PLATFORM, label="Outbound Bridge", adapter_factory=OutboundBridgeAdapter,
        check_fn=check_requirements, validate_config=validate_config, is_connected=validate_config,
        required_env=["OUTBOUND_BRIDGE_ENDPOINT"], install_hint="stdlib only",
        env_enablement_fn=_env_enablement,
        allowed_users_env="OUTBOUND_BRIDGE_ALLOWED_USERS", allow_all_env="OUTBOUND_BRIDGE_ALLOW_ALL_USERS",
        max_message_length=0, emoji="🔌",
        platform_hint="You are talking to a user through a private bridge. Plain markdown is fine.")
    # Docs mention `trusted_inbound`; the v0.21.5 image has no such field -> feature-detect.
    try:
        import dataclasses
        from gateway.platform_registry import PlatformEntry
        if "trusted_inbound" in {f.name for f in dataclasses.fields(PlatformEntry)}:
            kwargs["trusted_inbound"] = True
    except Exception:
        pass
    ctx.register_platform(**kwargs)
    for h in _HOOKS:
        ctx.register_hook(h, _make_hook(h))

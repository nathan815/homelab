# Spike: Hermes platform-adapter plugin that dials OUT (`outbound_bridge`)

Question: can Hermes run inside an untrusted sandbox with **no inbound listener**, talking to a
trusted side by *dialling out* (like Muse's harness over a unix socket), using the supported
platform-plugin mechanism instead of `hermes acp`?

Verdict up front: **yes, it works end to end** on `nousresearch/hermes-agent:latest`
(= Hermes Agent **v0.21.5 (2026.9.24)**, upstream rev `749220ef`, image id `sha256:d4da4a40cd7a...`,
pulled 2026-10-08). Everything below was run; section 9 lists what was not.

## 1. How to run

Needs only Docker. All resources are prefixed `plugspike-`, nothing is published, no real keys
(the "API key" is `test-key`, the LLM is `mock_llm.py`).

```
./run.sh fresh                                   # network (--internal), volumes, mock LLM, seeds plugin+config
./run.sh scenario scenarios/02_stream_tool.txt   # starts trusted.py (listens), then Hermes (dials)
./run.sh scenario scenarios/04_interrupt_approval.txt --approve once   # (Hermes keeps running, re-dials)
./run.sh hermes-logs | llm-logs
./run.sh down                                    # removes all plugspike-* containers/volumes/network
```
Variants: unix socket on a shared named volume (default,
`OUTBOUND_BRIDGE_ENDPOINT=unix:///sock/trusted.sock`) or TCP
(`ENDPOINT=tcp://plugspike-trusted:9000 LISTEN=tcp://0.0.0.0:9000 ./run.sh scenario ...`).
`EXTRA_DOCKER_ARGS` passes extra `-e` flags (used for the authz tests).
Cold start of the gateway is ~20-35 s; the first turn after boot can take another ~30 s (see 5).
Scenario files start with `sleep 30` for that reason.

Files: `plugin/outbound_bridge/{plugin.yaml,__init__.py,adapter.py}` (the plugin),
`trusted.py` (trusted side, stdlib), `mock_llm.py` (OpenAI-compatible SSE mock: plain reply,
`TOOL` -> `echo hi`, `DANGER` -> `rm -rf /tmp/plugspike-danger`, `SLOW` -> 40 tokens @0.5 s),
`config/config.yaml`, `scenarios/*`, `captures/*` (real logs; `wire.ndjson` is the raw protocol).

## 2. Interface as actually used (v0.21.5 source, read from the image)

- `gateway/platforms/base.py::BasePlatformAdapter` (4767 lines). **Abstract** (all three docs-listed
  plus one more): `connect(*, is_reconnect=False) -> bool`, `disconnect()`, `send(chat_id, content,
  reply_to=None, metadata=None) -> SendResult`, **`get_chat_info(chat_id)`** (also `@abstractmethod`;
  docs call it optional - it is not).
- Optional overrides I used: `edit_message(chat_id, message_id, content, *, finalize=False)`,
  `send_typing(chat_id, metadata=None)`, `on_processing_complete(event, outcome)`,
  `_send_exec_approval_prompt(prompt: ExecApprovalPrompt)` (this is the hook the base's
  `send_exec_approval()` template calls; the runner decides "buttons" by checking the class overrides it,
  `run_turn_runner.py::_renders_exec_approval_buttons`).
- Inbound: `self.build_source(chat_id, chat_name, chat_type, user_id, user_name)` ->
  `MessageEvent(text, message_type=MessageType.TEXT, source, message_id)` ->
  `await self.handle_message(event)` (`gateway/platforms/event.py`).
- Helpers: `_mark_connected()/_mark_disconnected()`, `_set_fatal_error(code, msg, retryable=)`.
- Approval resolution: `tools.approval.resolve_gateway_approval(session_key, choice)`, choice in
  `once|session|always|deny` (same call the relay adapter uses).
- Registration (`adapter.py::register(ctx)`): `ctx.register_platform(name, label, adapter_factory,
  check_fn, validate_config, is_connected, required_env, install_hint, env_enablement_fn,
  allowed_users_env, allow_all_env, max_message_length, emoji, platform_hint)`; fields come from
  `gateway/platform_registry.py::PlatformEntry`. `ctx.register_hook(name, fn)` for lifecycle hooks.
- Config read via `gateway.platforms._shared.extra_or_secret(extra, key, ENV, default)`.

**Docs vs reality (v0.21.5):**
1. `trusted_inbound` does **not exist** in this image (`grep -r trusted_inbound /opt/hermes` -> nothing;
   `PlatformEntry` has no such field). The docs are ahead of the image. The working equivalent is the
   adapter property **`authorization_is_upstream` -> True** (`authz_mixin.py::_chat_scoped_grant`; used by
   the bundled `relay` and `a2a` adapters). The plugin feature-detects `trusted_inbound` with
   `dataclasses.fields(PlatformEntry)` and sets it if a newer image has it.
2. A user plugin dir **needs `__init__.py`** (`from .adapter import register`). Docs say plugin.yaml +
   adapter.py; with only those the gateway logs `Failed to load plugin 'outbound_bridge': No __init__.py`
   (to `errors.log`, easy to miss) while `hermes plugins list` still shows it "enabled".
3. A user plugin must be listed in `config.yaml` `plugins.enabled: [outbound_bridge]` (opt-in), and the
   platform needs `gateway.platforms.outbound_bridge.enabled: true` (or `env_enablement_fn` returning
   extra when `OUTBOUND_BRIDGE_ENDPOINT` is set - also implemented). `HERMES_ENABLE_PROJECT_PLUGINS`
   was not needed: `$HERMES_HOME/plugins/<name>/` (= `/opt/data/plugins`) is the "user" source.
4. `render_message_event` / `format_tool_event` (stream_events dispatcher, in base.py) are **dead code in
   this version**: `GatewayEventDispatcher` is never instantiated anywhere. Overriding them does nothing
   (I wrote that first, saw no output, then verified by grep). Streaming/tool-progress reach adapters
   only through `send()` + `edit_message()`. Use plugin hooks instead (below).

## 3. Wire protocol (newline-delimited JSON; Hermes connects, trusted listens)

trusted -> Hermes: `user_message {chat_id,user_id,id,text}`, `interrupt {chat_id}` (adapter injects `/stop`),
`approval_response {approval_id,choice}`, `ping`.
Hermes -> trusted: `hello`, `assistant_delta`, `assistant_text` (= gateway `send`), `assistant_edit`
(= gateway `edit_message`, with an adapter-derived `delta`), `tool_start`, `tool_end`, `approval_request`,
`stopped`, `done {outcome: success|cancelled|failure}`, `typing`, plus raw `hook` passthroughs
(`on_stream_start/end`, `pre/post_approval_*`). Real capture: `captures/wire.ndjson` (57 lines). Excerpts:

```
{"type":"hello","platform":"outbound_bridge","caps":[...],"ts":...}
{"type":"assistant_delta","text":"Hello ","turn_id":"2026...:834394e3"}
{"type":"assistant_text","chat_id":"main","message_id":"m3","text":"Hello  ▉","metadata":{"reply_to_message_id":"u1","expect_edits":true}}
{"type":"assistant_edit","chat_id":"main","message_id":"m3","text":"...You said: hi ▉","delta":" hi","finalize":false}
{"type":"assistant_edit",...,"text":"Hello from the mock LLM. You said: hi","delta":"","finalize":true}
{"type":"done","chat_id":"main","message_id":"u1","outcome":"success"}
{"type":"tool_start","tool":"terminal","args":{"command":"echo hi"},"tool_call_id":"call_2c65c2","turn_id":"..."}
{"type":"tool_end","tool":"terminal","tool_call_id":"call_2c65c2","result":"{\"output\": \"hi\", \"exit_code\": 0, \"error\": null}"}
{"type":"approval_request","approval_id":"44aa61af7f","chat_id":"main","command":"rm -rf /tmp/plugspike-danger","description":"delete in root path","choices":["once","session","always","deny"],"smart_denied":false,"text":"⚠️ Hermes wants ..."}
```
Source of each event: deltas/tool events from **plugin hooks** (`on_stream_delta` gives real model token
deltas with `kind`; `pre_tool_call`/`post_tool_call` give structured name/args/id/result; `agent_loop_stopped`
-> `stopped`); text/edits/typing/approval from the adapter methods; `done` from `on_processing_complete`.
Hooks are registered with `ctx.register_hook` in `register()` and fire on the agent worker thread, so
the adapter's `emit()` marshals with `call_soon_threadsafe`.

## 4. Results (all executed; logs in `captures/`)

| Item | Result |
|---|---|
| Hermes dials out (unix socket on a shared volume) | Works. `captures/run2_*`: `hermes connected (it dialled us)`. |
| Hermes dials out (TCP to container name on `--internal` net) | Works (`run6`, `run7`, `run_raw`). |
| Reconnect | Trusted restarted several times; plugin's retry loop (0.5 s -> 10 s backoff) re-dialled each time without restarting Hermes. |
| user message -> Hermes -> mock LLM -> back | Works (`run2`, `run4`). Mock saw `Authorization: Bearer test-key`. |
| Streaming | Works two ways: true token deltas via `on_stream_delta` hook; and gateway send-then-edit (`expect_edits:true`, cursor glyph ` ▉` appended - strip it; the plugin does for `delta`). Need `streaming.enabled: true` for the edit path. |
| Tool activity | Works, structured via hooks (`tool_start`/`tool_end`, with `tool_call_id`). The gateway also sends a plain text chrome line (`💻 Running echo hi`) via `send()` with empty metadata - indistinguishable from assistant text except by content, so prefer the hooks and drop it (`display.tool_progress: off`, not tested). |
| Interrupt | Works. `interrupt` -> adapter injects `/stop` -> `stopped` event, text `⚡ Stopped...`, `done outcome=cancelled`; mock logged the client disconnect mid-stream. Sending a normal message while busy instead interrupts+queues (default `/busy interrupt`), with a one-time tip text. |
| Exec approval round trip | Works both ways. `DANGER` -> `approval_request` -> `approval_response once` -> tool ran, and `deny` -> `BLOCKED: Command denied by user` returned to the model (once: `run4`, `run_raw`; deny: `scenarios/05_deny_sethome.txt` was run and worked, but its console output was not saved to `captures/`). Requires `approvals.mode: manual`; pattern matched was "delete in root path". |
| Slash commands | `/status`, `/help` (full list, ~70 commands), `/sethome`, `/memory pending` all answered through `send()`. `/new /stop /approve /deny /model /queue /steer /busy /goal /loop /heartbeat /bg /btw /compress /rollback` etc. are in the list (only `/stop`, `/status`, `/help`, `/sethome`, `/memory pending` exercised). |
| Memory / cron | Memory command surface present; cron delivery needs a home channel (`/sethome` worked, "Cron jobs ... will be delivered here"). A cron job actually firing back through the bridge was **not** tested. Cron from a separate process would need `standalone_sender_fn` (not implemented; in-gateway cron uses the live adapter). |
| Authorization | See 6. |

## 5. Operational findings / gotchas

- **Inbound is gated during startup.** A message sent right after connect is queued
  (`Queued inbound message during gateway startup restore`) and a premature empty `done` is emitted; it
  is replayed later. Cold start: connect at ~20-35 s, first turn up to ~35 s more. A real bridge needs a
  readiness signal; `hello` is sent at connect, not at ready. (Run 1 in my notes lost a message this way
  because the harness exited before the replay.)
- **`done` races the next message.** `on_processing_complete` fires before the session guard is released;
  a follow-up sent immediately gets the "Interrupting current task" busy path (seen in `run_raw`).
  Trusted side should wait ~100-300 ms after `done`, or the adapter should delay it.
- **First-run chrome**: "No home channel is set" text and a "very first message" system note appended to the
  first user turn (the mock echoed it). Set a home channel / seed state to suppress.
- Without `authorization_is_upstream` Hermes replies with a pairing code (see 6).
- Reused data volume + `gateway run --no-supervise` fails: "A gateway is already running under s6" (the
  profile gets registered as an s6 service on first boot). The harness uses a fresh volume per boot.
- Container `restart` of a used volume fails the same way. Not a plugin issue, but matters for ops.
- Internal network = no internet: Hermes logs failed fetches (model catalog, tirith download, pypi
  edge-tts, openrouter catalog) but runs fine. Real deployment will have the egress policy question.

## 6. Authorizing the bridge user

- Default: unknown sender -> reply `Hi! I don't recognize you yet ... pairing code ...` and message dropped
  (`captures/run6_*`, `Unauthorized user: trusted-user on outbound_bridge`). Needs `hermes pairing approve`.
- Fix A (used by default): `authorization_is_upstream = True` on the adapter -> all inbound trusted
  (`run2`, `run4`, `run_raw`). Appropriate here because the only peer is the endpoint we dialled.
- Fix B: `OUTBOUND_BRIDGE_ALLOWED_USERS=trusted-user` (registered via `allowed_users_env`) with
  `OUTBOUND_BRIDGE_UPSTREAM_AUTH=false` -> works (`run7`). `OUTBOUND_BRIDGE_ALLOW_ALL_USERS` is registered but untested.

## 7. Listener check (the key question)

`/proc/net/tcp`, `tcp6` state `0A` inside the running Hermes container, with the plugin connected:
- **Only** `127.0.0.11:<random>` TCP + UDP: Docker's embedded DNS resolver; `/proc/*/fd` search shows
  **no process in the container owns it**. (Checked on a unix run and a TCP run.)
- **Out-of-the-box the image DOES open a listener**: `127.0.0.1:8642` - the `api_server` platform, which
  `stage2-hook.sh` auto-enables by generating `API_SERVER_KEY` into `.env` (seen in the first boot:
  `API server listening on http://127.0.0.1:8642`). Loopback only, but not zero. Disabled by
  `gateway.platforms.api_server.enabled: false` in config.yaml (explicit disable beats the env; verified: gone).
- Dashboard: s6 service `dashboard` exists but is a no-op unless `HERMES_DASHBOARD=1` (default
  would bind 0.0.0.0:9119 with an auth gate). Not enabled here; confirmed no 9119.
- Health endpoint: none opened in this config (no separate health port seen).
- **Unix-socket listeners exist** (filesystem-ACL only): `/opt/data/gateway.sock` (control socket,
  `identify`/`status` JSON verbs, 0600 hermes) and `/opt/data/state/gateway.loop-tick.<pid>.sock`. Not TCP,
  but "no listener at all" is false in the strict sense; inside a sandbox VM they are only reachable by
  local processes (including the agent's own `terminal` tool, which runs as the same user).
- The one established TCP connection was the bridge to the trusted side (TCP run).

## 8. Effort to productionize & stability risks

Effort (rough, one engineer who knows Hermes): protocol spec + versioning + auth on the link
(mTLS or a unix-socket peer cred check, heartbeat/ping, backpressure, message ids/acks, replay on
reconnect so a dropped link does not lose `done`/approvals): ~1-1.5 weeks. Readiness gate + done-ordering
fix, multi-chat/session mapping, attachments/media (`send_image`, `send_document` are not implemented here),
cron `standalone_sender_fn`, `/model`-style config surfacing: ~1 week. Image/hardening (disable api_server,
bootstrap without s6 registration issues, egress policy, pin version, CI contract tests against a new
Hermes tag): ~1 week. Total ~3-4 engineer-weeks to something I would run; the spike core is ~300 lines.

Stability risks (real, observed):
- The plugin API is unstated/unstable: docs already disagree with the shipped image (`trusted_inbound`,
  `__init__.py`, `get_chat_info` abstract). base.py is 4.7k lines with `PLUGIN-COMPAT (revert-scheduled)`
  shims for a "Sep 2026 decomposition"; the v0.21.5 release line is a few weeks old and moves daily.
- Private-ish members I rely on: `_send_exec_approval_prompt`, `_mark_connected`, `_set_fatal_error`,
  `authorization_is_upstream`, `tools.approval.resolve_gateway_approval`, hook kwarg names
  (`delta`, `kind`, `tool_call_id`, `turn_id`). Any rename silently breaks us (hooks fail open / log only).
- Streaming edit protocol embeds cursor glyphs and relies on `edit_message` semantics.
- Dead-code surfaces (stream_events dispatcher) suggest the intended structured API may land later and
  change what adapters must implement.
- Must pin the image digest and run a contract test (this repo's scenarios) per upgrade.

## 9. NOT verified

Real LLM providers; non-text media/attachments; multiple chats/users concurrently; cron job actually
firing through the bridge; memory writes/skills creation via the agent; `/new`, `/model`, `/queue`, `/steer`
and most other slash commands; `display.tool_progress: off`; `ALLOW_ALL_USERS`; smart/auto approval modes;
approval timeout behaviour (`--approve none`); behaviour when the link drops mid-turn or mid-approval
(reconnect only tested between turns); long outputs/`max_message_length` chunking (set to unlimited);
Linux-host unix sockets (used a Docker named volume; no macOS bind-mount sockets); arm64-vs-amd64 differences;
resource use under load; the `trusted_inbound` option (absent in this image); `HERMES_ENABLE_PROJECT_PLUGINS`
path; the bridge under the exact sandbox-VM topology you plan.

## 10. Honest verdict vs `hermes acp` over stdio

The plugin path works and gives the *gateway* feature set for free: slash commands, approvals,
session persistence/queueing/interrupt semantics, memory, cron hooks, `/status`. It dials out cleanly and
authorization is solvable. But it is a lot of surface to inherit: the full multi-platform gateway process
(~58 bundled skills sync, many plugins imported, ~35 s cold start, default loopback api_server and
unix control sockets to turn off), an unstable undocumented internal API we monkey-patch via private
members, and protocol glue we must own (readiness, done ordering, replay). ACP over stdio is, by design,
a narrow documented client protocol for exactly "an editor/host drives the agent", has no gateway, no
listeners at all, and its stdio pipe can be plumbed over any outbound channel by a thin relay. If ACP can
carry what you need (streaming, tool events, permission requests, cancel), I would prefer it as the primary
integration and treat this adapter as the fallback for features ACP lacks (cron, multi-platform delivery,
gateway slash commands). I have not run ACP, so that preference rests on the architecture, not on a test.

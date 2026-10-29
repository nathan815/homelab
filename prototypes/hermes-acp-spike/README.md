# Hermes ACP-over-stdio spike

Goal: can a trusted process drive `hermes acp` (JSON-RPC over stdio) inside a sandbox that has no inbound listener and no internet?
Everything below was actually run on 2026-10-08 against `nousresearch/hermes-agent:latest` (hermes-agent 0.21.5, image digest sha256:d4da4a40...), with a mock LLM. No real keys anywhere (`test-key`).

## Files
- `mock_llm.py`  mock OpenAI chat-completions server (SSE streaming). Triggers in the user text: `TOOL:<cmd>` -> calls the `terminal` tool; `DANGER` -> a recursive delete under /tmp (triggers approval); `SLOW` -> 60 words at 0.5s.
- `config.yaml`  seeded into `/opt/data/config.yaml` (provider `custom`, base_url `http://acpspike-mock:8080/v1`, api_key `test-key`, `approvals.mode: manual`).
- `setup.sh` / `teardown.sh`  create/destroy `acpspike-net` (docker `--internal`: no internet), `acpspike-mock`, `acpspike-hermes` (idle `sleep infinity`, no published ports), volume `acpspike-data`.
- `client.py`  stdlib ACP client (`AcpClient` class + demo `main`). `resume_test.py` reconnect test. `listener_check.sh` listener check. `shim.py` (in-sandbox, connects OUT), `trusted_side.py` (outside, listens), `bridge_run.sh` end-to-end through the shim.
- `run1.log` (full raw wire capture, direct), `run_resume.log`, `run_bridge.log` (via shim).

## Run
```
./setup.sh
python3 client.py --raw          # direct: spawns `docker exec -i -u hermes acpspike-hermes hermes acp`
python3 resume_test.py           # reconnect / resume / load
./listener_check.sh              # /proc/net/tcp before vs during
./bridge_run.sh                  # client -> trusted_side -> (outbound TCP) -> shim -> hermes acp
./teardown.sh
```
Gotchas: use `-u hermes` with docker exec (root would write root-owned files in /opt/data). The image has no `ss`/`netstat`; use /proc/net/tcp. `docker exec` bypasses the s6 wrapper but works (env comes from image ENV; `hermes` is on PATH). First `session/new` takes ~8s (plugin load, MCP discovery retry); initialize ~5s cold start.

## Protocol facts (observed)
- Framing: newline-delimited JSON, one object per line; stdout carries only JSON-RPC, logs go to stderr. Protocol version 1. Method names are the standard ACP ones: `initialize`, `authenticate`, `session/new|load|resume|fork|list|prompt|cancel|set_mode|set_model`, notification `session/update`, agent->client request `session/request_permission`. `session/cancel` is a notification (no id). (Only initialize, authenticate, new, prompt, cancel, list, resume, load were exercised.)
- Handshake: `initialize` -> `authenticate{methodId}` -> `session/new`. Advertised auth methods: `custom` (runtime creds from config) and `hermes-setup` (terminal). Authenticate succeeded with config-provided creds; I did not test whether session/new works without calling authenticate.
- Credentials/provider come from `/opt/data/config.yaml` + `.env` in the sandbox, not from ACP messages.

Real captured messages (abridged with `...`):
```
>> {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1,"clientCapabilities":{"fs":{"readTextFile":false,"writeTextFile":false}},"clientInfo":{"name":"acpspike","version":"0"}}}
<< {"jsonrpc":"2.0","id":1,"result":{"agentCapabilities":{"loadSession":true,"promptCapabilities":{"image":true},"sessionCapabilities":{"fork":{},"list":{},"resume":{}}},"agentInfo":{"name":"hermes-agent","version":"0.21.5"},"authMethods":[{"id":"custom","name":"custom runtime credentials",...},{"id":"hermes-setup","type":"terminal","args":["--setup"],...}],"protocolVersion":1}}
>> {"jsonrpc":"2.0","id":3,"method":"session/new","params":{"cwd":"/tmp","mcpServers":[]}}
<< {"jsonrpc":"2.0","id":3,"result":{"models":{"availableModels":[{"modelId":"custom:mock-model",...}],"currentModelId":"custom:mock-model"},"modes":{"availableModes":[{"id":"default"},{"id":"accept_edits"},{"id":"dont_ask"}],"currentModeId":"default"},"sessionId":"62a7e713-0d20-402a-8f04-59b1f6511bbd"}}
>> {"jsonrpc":"2.0","id":4,"method":"session/prompt","params":{"sessionId":"62a7...","prompt":[{"type":"text","text":"say hello"}]}}
<< {"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"62a7...","update":{"content":{"text":"Hello ","type":"text"},"messageId":"3e6bff57-...","sessionUpdate":"agent_message_chunk"}}}
<< {"jsonrpc":"2.0","id":4,"result":{"stopReason":"end_turn","usage":{"cachedReadTokens":0,"inputTokens":0,"outputTokens":0,"thoughtTokens":0,"totalTokens":0}}}
```
Other update kinds seen: `available_commands_update`, `usage_update{size,used}`, `session_info_update{title,updatedAt,_meta.hermes.sessionProvenance}`, `user_message_chunk` (replay only). Note `usage` in the prompt result is all zeros.

Tool call (prompt `TOOL:echo hi`):
```
<< {...,"update":{"content":[{"content":{"text":"$ echo hi","type":"text"},"type":"content"}],"kind":"execute","locations":[],"title":"terminal: echo hi","toolCallId":"tc-491293f5ae60","sessionUpdate":"tool_call"}}
<< {...,"update":{"content":[{"content":{"text":"terminal result\n- **output:** hi\n- **exit_code:** 0","type":"text"},"type":"content"}],"kind":"execute","status":"completed","toolCallId":"tc-491293f5ae60","sessionUpdate":"tool_call_update"}}
```
The initial `tool_call` has no `status` field; completion is a `tool_call_update` with `status: completed|failed`. Results are markdown text, not structured (no rawOutput).

Permission request (prompt `DANGER`, `approvals.mode: manual`; agent-originated request, the id is the agent's own counter starting at 0):
```
<< {"jsonrpc":"2.0","id":0,"method":"session/request_permission","params":{"options":[{"kind":"allow_once","name":"Allow once","optionId":"allow_once"},{"kind":"allow_always","name":"Allow for session","optionId":"allow_session"},{"kind":"allow_always","name":"Allow always","optionId":"allow_always"},{"kind":"reject_once","name":"Deny","optionId":"deny"},{"kind":"reject_always","name":"Deny always","optionId":"deny_always"}],"sessionId":"62a7...","toolCall":{"content":[{"content":{"text":"delete in root path\n$ <recursive delete of /tmp/acpspike-victim>","type":"text"},"type":"content"}],"kind":"execute","rawInput":{"command":"<the command>","description":"delete in root path"},"status":"pending","title":"delete in root path: <command>","toolCallId":"perm-check-1"}}}
>> {"jsonrpc":"2.0","id":0,"result":{"outcome":{"outcome":"selected","optionId":"allow_once"}}}
```
- allow_once: tool ran, result says "approved by the user". deny: tool_call_update `status: failed`, text "BLOCKED: User denied this command...", and the turn continued normally (`end_turn`). The permission `toolCallId` (`perm-check-N`) differs from the real tool's `tc-...` id, so a UI must correlate by command text/order (gotcha). allow_session/allow_always are offered but were not exercised.
- Cancel: `{"jsonrpc":"2.0","method":"session/cancel","params":{"sessionId":...}}` sent 2.5s into a SLOW stream (some chunks already received) -> the pending prompt returned `{"stopReason":"cancelled"}` 0.44s later (0.08s via the shim). Cancel during a pending permission request or a long-running tool was NOT tested.
- Reconnect (`resume_test.py`): a fresh `hermes acp` process after the old one exited sees sessions via `session/list` (state in /opt/data/state.db). `session/resume` replays user messages (`user_message_chunk`) before its response; `session/load` replays both user and agent messages. Prompting a resumed session worked. Only plain text history was tested, so unknown whether tool-call history is replayed.
- Streaming: token-level `agent_message_chunk` deltas arrive live (mock streamed word by word).

## Listener check
`/proc/net/tcp`, tcp6, udp, udp6 in the container before and while `hermes acp` ran (live ACP session): the only LISTEN socket is `127.0.0.11:39321`, Docker's embedded DNS resolver, present before hermes started and unrelated to it. `hermes acp` opened no TCP/UDP listener. The container had no published ports (`docker port` empty). Not checked: unix sockets, other s6 services (only main-hermes observed), listeners when browser/MCP tools are enabled.
Network isolation: from the sandbox container, DNS resolution of example.com fails (internal network). Hermes logged a failed tirith (security scanner) download on first terminal use and carried on.

## Bridge (shim)
`client.py` -> `docker run -i` `trusted_side.py` (listens on :9000 on the internal network, bridges its stdio to the socket) <- outbound TCP from `shim.py` inside the sandbox -> `hermes acp` child stdio. Trusted side logged `shim connected from 172.23.0.3`. The same client script (initialize, tool call, allow, deny, cancel, list) passed unchanged through the shim (`run_bridge.log`). Shim is ~20 lines, a pure byte copy. A real deployment would swap TCP for vsock/unix socket; not tested (no vsock; unix sockets across Docker Desktop macOS mounts are unreliable so TCP was used).

## Verdict
Viable as the control channel. Everything a phone app needs exists and worked here: token streaming, structured tool-call start/finish events, human-in-the-loop approvals with a clean allow/deny option set, fast prompt cancel, persisted sessions with list/resume/load across process restarts, and a byte-transparent transport so the shim approach works with no listener in the sandbox. Caveats: ACP is marked unstable in Hermes (`use_unstable_protocol=True`), so pin the image version; cold start ~5s plus ~8s for the first session; permission tool IDs don't match tool-call IDs; tool output is markdown text; the trusted side must itself be the ACP client (implement request_permission and answer before Hermes' timeout, which denies by default); the phone should talk to a trusted backend that holds the ACP connection, not to Hermes directly.

## NOT verified
- Real LLM providers; only a mock (real tool-call argument shapes, reasoning/thought chunks).
- Disconnect mid-turn: what happens to a running prompt or pending permission if the stdio pipe drops (does the turn continue, is output buffered or replayed on resume?). This is the key gap for a phone app with flaky links: completed history replays on load, but catch-up of in-flight turns is not demonstrated.
- Cancel while waiting on permission or during a long tool run; allow_session/allow_always semantics; fork; set_mode/set_model; image prompts; MCP servers via session/new; concurrent sessions in one process; file-edit approval flow (fs capabilities declared false).
- Whether `authenticate` is required before session/new; behaviour with no config.
- vsock/unix-socket transport; Linux host (tested on macOS Docker Desktop); non-s6 / `--init` paths; resource limits.

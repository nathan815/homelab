# Egress approval proxy (prototype)

An agent sandbox with no network route out except a TLS-intercepting proxy. Requests not covered by a rule are
**held** while the user is asked: Allow (once) / Always allow / Deny. Deny and timeout return a clear 403 the agent
can read. "Always allow" stores a reviewable, revocable rule.

## Architecture

```
                 sandbox_net (internal: true, no route out)
   ┌───────────┐        ┌──────────────────────────────────────────┐        egress net
   │  sandbox  │ :8080  │ proxy container (mitmproxy + addon.py)   │───────► internet
   │ curl/py/  │───────►│  1. SSRF guard (non-public dest -> 403)  │
   │ node      │        │  2. rules.json match -> allow / deny     │
   │ CA: pub   │        │  3. else HOLD flow, create pending card  │
   │ cert only │        │                                          │
   └───────────┘        │  approval API (aiohttp, same process)    │
        │               │  bound ONLY to 172.30.9.2 (control net)  │
        ✗ no route      └───────────────┬──────────────────────────┘
        to control net                  │ control net 172.30.9.0/24
                                        ▼
                         127.0.0.1:8081 on the host  ◄── user / app / UI page
Volumes: ca-private (CA key, proxy only) | ca-public (cert only, ro in sandbox) | state (rules.json, decisions.jsonl)
```

Files: `proxy/addon.py` (all logic, ~250 lines), `proxy/ui.html` (stub approval page), `sandbox/` (image + entrypoint
that installs the public CA), `docker-compose.yml`, `test.sh`.

## Run

```
./test.sh                 # builds, runs everything, prints PASS/FAIL, tears down (docker compose down -v)
KEEP=1 ./test.sh          # leave the stack up afterwards
docker compose up -d --build   # manual use; open http://127.0.0.1:8081/ for the approval page
docker compose exec sandbox curl -sS https://example.com/    # blocks until you click a button
```
Host needs docker, curl, jq. `APPROVAL_TIMEOUT` (seconds, default 120) controls hold time; test.sh sets 10.

### Approval API (trusted side, http://127.0.0.1:8081)
`GET /approvals` · `POST /approvals/{id}/decision {"decision":"allow_once|always_allow|deny"}` · `GET /rules` ·
`DELETE /rules/{id}` · `GET /events` (SSE: `pending`, `resolved`) · `GET /log?n=50` · `GET /` (HTML page).

### Rules
Stored as `[{id, origin, methods, path_prefix, action, created, note}]`. "Always allow" on a GET/HEAD creates
`origin=scheme://host[:port]`, `methods=[GET,HEAD]`, any path. "Always allow" on a POST/PUT/PATCH/DELETE creates a rule
for that single method and exact path only. Deny rules (hand-edited) beat allow rules.

## What the tests prove (37 checks, all passing on the last two runs)

| Test | Proves |
|---|---|
| CA hygiene | sandbox gets only `mitmproxy-ca-cert.pem`; no private key anywhere in its filesystem |
| hold + allow_once | unlisted URL creates a card, curl stays blocked, approval releases it with real content; no rule saved |
| card text | "Allow the agent to browse https://example.com/?" |
| deny | 403, plain-text body saying the user denied it and not to retry |
| timeout | with no answer, 403 "did not respond ... denied by default"; pending entry cleaned up |
| always_allow | rule is scheme+host, GET/HEAD; second request (and other paths) pass with no prompt |
| POST with GET rule | still prompts; card says "send data to", shows size 27; `password=hunter2` redacted in preview |
| revoke | `DELETE /rules/{id}` -> same URL prompts again |
| requests / node | work through the proxy with CA trusted; cert issuer really is mitmproxy |
| no-route | `curl --noproxy`, curl to 1.1.1.1, raw python socket: all fail (DNS fail / Network unreachable) |
| approval isolation | sandbox cannot reach 8081 via `proxy` or `172.30.9.2` (curl exit 7); via the proxy itself it gets a hard 403 and no card is created; `localhost` targets and CONNECT to ports other than 80/443 are refused |
| log | every line of `decisions.jsonl` has time/method/url/decision/source; sources seen: user:allow_once, user:deny, timeout, guard, rule:<id> |

Observed (not asserted): `getent hosts example.com` in the sandbox returns nothing, so Docker's embedded DNS does not
forward external names on an `internal` network, on this Docker Desktop version.

## Deviations / platform notes
- Approval service is folded into the mitmproxy addon (same process), so it runs in the proxy container; isolation is
  by network (bound only to the control-net IP, no route from `sandbox_net`), not by separate containers.
- Docker Desktop here is linux/amd64 under a VM. Publishing port 8081 from a container attached to an `internal`
  network works only because `gw_priority` is set on `egress`; without it Docker may pick the wrong network.
- `connection_strategy=lazy` so unapproved hosts are not even connected to upstream.
- The sandbox runs its entrypoint as root (to run `update-ca-certificates`) with all capabilities dropped.
- Added beyond spec: SSRF guard and CONNECT port restriction. Without them the agent could ask the proxy to
  fetch the approval API or the host's LAN, since the proxy can reach networks the sandbox cannot.

## Known gaps / next steps (be skeptical of this prototype)
1. **No auth on the approval API.** Protection is network separation only. Anything on the host's 127.0.0.1:8081
   (or any process on the control net) can approve. Needs a per-user token / mTLS, and the agent runtime must never
   share a host or netns with it.
2. **Data can leave inside an "allowed" GET.** A GET rule on a host allows arbitrary query strings and headers
   (`?q=<secrets>`), and allowed hosts that accept user content (pastebins, GitHub gists, search engines) are
   exfil channels. Cards only show the URL; consider path-scoped rules, query-length limits, and showing headers.
3. **Non-HTTP protocols.** Only 80/443 tunnels are allowed and TLS is intercepted. Raw TCP/UDP/ICMP has no
   route (verified for TCP). HTTP/3 (QUIC) is not proxied (UDP has no route, so clients fall back or fail).
   Non-TLS traffic on 443 is not specially handled.
4. **WebSockets.** Upgrade is judged once at the handshake request (mitmproxy passes WS frames through); messages
   are neither inspected nor re-approved. Not tested.
5. **Cert-pinned clients and clients ignoring the CA** break by design (some CLIs, Go with own roots, mobile SDKs).
   `HTTP(S)_PROXY` is a convention; the safety comes from "no route", not env vars.
6. **DNS.** The sandbox resolves nothing externally here (observed), and the proxy resolves on its behalf, so the agent
   cannot tunnel data over DNS from the sandbox. The SSRF guard resolves separately from mitmproxy's connect, so a
   DNS-rebinding race is possible. Other runtimes/Docker versions/Kubernetes may forward DNS: verify per platform.
7. **Timeouts / liveness.** Held requests tie up the agent's HTTP client (client timeouts may fire first; the hold
   is then logged `abandoned`). Pending state is in memory: restarting the proxy loses pending cards (rules persist).
   Concurrent identical requests create separate cards (no coalescing).
8. **Redaction is regex-based** and best-effort; binary bodies show only size. Compressed bodies are not decoded.
9. **Rule granularity:** host-wide for reads. No expiry, no per-session scope, no wildcard/subdomain rules, no
   "always deny" button. Host header vs. SNI mismatch (domain fronting through shared CDNs) not analysed.
10. Single sandbox / single user; no sandbox identity on cards.

### Mapping to an iOS app + push
Proxy/approval service runs on the trusted server. On creating a pending card it sends a push (APNs, via a small
notifier subscribed to `/events`) with the card id and text; notification actions map to the three buttons and call
`POST /approvals/{id}/decision` over an authenticated channel (WireGuard/Tailscale + token), exposed through a gateway
that adds auth, never the raw port. The app lists `/approvals` and `/rules` (revoke) and shows the decision log.
The push should carry only the redacted card text; `expires_at` is already in each card so the app can show a countdown
and greys out expired cards (404 on late decide). Consider a per-session "allow for this task" option, since
approve-every-request fatigue is the main UX risk.

### Pointing Hermes (NousResearch hermes-agent, terminal backend) through it
Run the Hermes container (and any terminal-backend sandbox it spawns) only on `sandbox_net`: no other networks, no
published ports. Hermes also needs to reach its LLM endpoint: either add that one host as a standing allow rule (HTTPS
to the model provider through this proxy), or put a small model gateway on `sandbox_net` that holds the API key so the
key never lives in the agent container. Set `HTTP(S)_PROXY`, `SSL_CERT_FILE`, `REQUESTS_CA_BUNDLE`,
`NODE_EXTRA_CA_CERTS` as in `docker-compose.yml`. If its terminal backend spawns sibling containers via the Docker
socket, those would bypass this (and the socket is root-equivalent): the backend must instead launch on `sandbox_net`
or be a nested runtime with no host socket. Not tried in this prototype.

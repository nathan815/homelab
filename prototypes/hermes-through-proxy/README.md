# Spike: Hermes Agent inside the egress approval-proxy sandbox

Question: can `nousresearch/hermes-agent` (v0.21.5, image `:latest`, amd64) run on the route-less `sandbox_net` with all
egress forced through the TLS-intercepting approval proxy from `../egress-proxy` (unmodified)?
**Short answer: yes for model calls, terminal tool, npm/uv/apt and Chromium, after a handful of explicit trust/config
steps. Hermes' web_search/web_extract do not fetch the page themselves (they call a third-party API), and a stock
image lazily downloads things at runtime that you will want to bake in.** Details and verdict below.

## Setup (all in this dir; nothing outside it touched)
- `docker-compose.override.yml` layered on `../egress-proxy/docker-compose.yml` (`./dc.sh` = `docker compose -p hermesproxy -f ../egress-proxy/docker-compose.yml -f docker-compose.override.yml`).
  Relative paths in an override resolve against the FIRST -f file's dir, so `dc.sh` exports `HP=$PWD` and the override uses `${HP}/...`
  (my first attempt made Docker create empty dirs inside `egress-proxy/`; removed, no tracked file changed).
- proxy: same image/addon, but command runs `wrapper/wrapper.py` (imports the original `/addon/addon.py`, re-exports its addons,
  patches `addon.guard` so the private-IP mock hosts pass the SSRF guard, appends a `Swap` addon) plus `ssl_insecure=true` (mock has a self-signed cert).
  Published approval port 8091; control subnet moved to 172.30.99.0/24 (avoid collisions).
- `mockllm` (egress net only, aliases `llm.mock.test`, `firecrawl.mock.test`, `search.mock.test`, HTTPS :443): OpenAI-compatible, streams, emits tool calls
  from prompt triggers (`BROWSE url`, `EXTRACT url`, `SEARCH q`, `TERM cmd`), logs the Authorization header it receives.
- `hermes` (sandbox_net only, no ports): stock image, custom entrypoint `hermes/entry.sh` that installs the proxy CA into the system store then execs the stock entrypoint. `command: sleep infinity`; I drive it with `docker exec ... hermes chat -q`.
  Env: HTTP(S)_PROXY, NO_PROXY=localhost,127.0.0.1, SSL_CERT_FILE, REQUESTS_CA_BUNDLE, NODE_EXTRA_CA_CERTS, NODE_USE_ENV_PROXY=1, AGENT_BROWSER_EXECUTABLE_PATH.
- `config.yaml`: provider custom, `base_url: https://llm.mock.test/v1`, `api_key: PLACEHOLDER_KEY`, `browser.backend: "off"`.
- `scripts/watch.py MODE`: host-side poller of the approval API (deny / allow_once / slow:N / holdchat / slowchat:N; host allow list becomes always_allow). `scripts/setup.sh`, `scripts/trust_matrix.sh`.
- Gotcha: `docker compose up -d --force-recreate proxy` alone broke the published 8091 port (Docker forwarded to the egress-net IP, API listens on control-net IP). Full `down`/`up` fixes it. Same fragility the base README mentions (`gw_priority`).

## Per-component CA trust (measured, `scripts/trust_matrix.sh`)
System store (`update-ca-certificates`) alone is NOT enough for Hermes' Python: it uses certifi.
| Client | Result |
|---|---|
| python `requests` | needs `REQUESTS_CA_BUNDLE`; `SSL_CERT_FILE` alone -> SSLError |
| python `httpx` / `openai` SDK (Hermes model calls) | needs `SSL_CERT_FILE`; `REQUESTS_CA_BUNDLE` alone -> `CERTIFICATE_VERIFY_FAILED` / `APIConnectionError` |
| Hermes itself | uses both (openai SDK for chat, requests for `/v1/models`), so set BOTH; both worked pointing at the system bundle |
| uv (lazy-installs, runs as Hermes child) | worked through the proxy with SSL_CERT_FILE set (PyPI downloads succeeded) |
| node 26 `fetch`/npm/npx | needs `NODE_USE_ENV_PROXY=1` (otherwise ignores proxy: `EAI_AGAIN`, i.e. the no-route net blocks it, fail-closed) AND `NODE_EXTRA_CA_CERTS` (else `UNABLE_TO_VERIFY_LEAF_SIGNATURE`) |
| apt-get | works via http_proxy (deb.debian.org is plain http; proxy sees it) |
| curl in terminal tool | works (system store); proxy env is passed into the terminal tool env |
| Chromium (Playwright chrome-headless-shell via agent-browser) | ignores system store, SSL_CERT_FILE, NODE_EXTRA_CA_CERTS: `net::ERR_CERT_AUTHORITY_INVALID`. Needs an NSS db in the HOME of the browser process. Hermes runs the browser with **HOME=/opt/data/home**, so `certutil -d sql:/opt/data/home/.pki/nssdb -A -n mitmproxy -t 'C,,' -i ca.pem` (package `libnss3-tools`, NOT in the image; I apt-installed it through the proxy). A db in `/opt/data/.pki` did not work (wrong HOME). Alternative hack that also worked in a direct run: `--ignore-certificate-errors-spki-list=<sha256 of CA SPKI>` (mitmproxy leaf certs reuse the CA key); not tried inside Hermes. |
Chromium honored the proxy by itself (agent-browser passes `--proxy-server=http://proxy:8080` from env, bypass list localhost). HTTP/2 to example.com via the proxy worked; WebSockets not exercised.

## Model calls through the proxy (mock on egress side)
Every Hermes request to `llm.mock.test` became a normal card: `GET /v1/models`, `POST /api/show` (x2, Ollama-style probe), `POST /v1/chat/completions` (body ~52 KB: system prompt + tool schemas), then a second `POST /chat/completions` (title generation). Streaming SSE works through mitmproxy. Hermes says nothing about the proxy; it works.
- **Deny** (user:deny): Hermes fails in ~3 s, no retries ("Attempt 1/3, not retryable"), prints the proxy body verbatim. But its generic hint is misleading ("Your API key was rejected by the provider ... run hermes setup") because it classifies any 403 as auth failure.
- **Timeout** (no answer, proxy 120 s): same 403 text ("did not respond within 120s ... denied by default"), same non-retry, run ends after ~2m15.
- **Slow approval** (45 s per card, default proxy timeout): works, but Hermes does the pre-flight probes serially, so a first turn needed 5 sequential approvals (~100 s); the model call itself waited 45 s fine.
- **Very slow approval** (proxy timeout raised to 500 s, chat card answered after 260 s): Hermes' stream stale timeout (~180 s) fired, it opened a NEW request (second card at +182 s). Approving the first card forwards a request nobody waits for (mock got extra POSTs; 33 chat POSTs total across the spike); stale cards stay pending until the client TCP disconnect (`abandoned` rows logged only at container teardown). The retry pattern repeated and I stopped it at 550 s. So practical ceiling for LLM approvals is ~180 s unless HERMES_STREAM_STALE_TIMEOUT is raised.
- Unanswered cards at startup stall Hermes: the lazy `uv pip install edge-tts` (PyPI) is held for the full approval timeout before the model call proceeds.

## Credential-injection demo (placeholder -> real key at the proxy)
Hermes config/env: `api_key: PLACEHOLDER_KEY`. `wrapper.py` Swap addon runs after the approval addon allowed the request and, for host `llm.mock.test`, replaces `Authorization` when it contains the placeholder with `Bearer <contents of /run/secrets/real_key>` (file mounted only into the proxy container).
Result (mock's `received.jsonl`): all Hermes calls arrived with `Authorization: Bearer sk-real-looking-secret` (56 requests incl. `/v1/models` via requests, `/api/show` via httpx, `/v1/chat/completions` via OpenAI SDK); my own probes using key `x` were not swapped (`Bearer x`). Leak scan: `grep -rI sk-real-looking /` inside the Hermes container (all files incl. /opt/data logs, sessions, state.db, backups) = no hits; no process env contains it (two s6 procs unreadable); `docker inspect` env of the hermes container has only the placeholder. Only the placeholder appears in `/opt/data/config.yaml`. Caveats: the proxy's own `decisions.jsonl` redacts bearer tokens (verified in code, not by grep for this exact value), a model that echoes headers is not a leak path here, and TLS to the real provider was not exercised (mock is `ssl_insecure`).

## Web / browser tools
- **terminal** (`curl https://example.com/`): works, card "Allow the agent to browse https://example.com/?", content returned.
- **browser tool**: default backend in this version is Browser Use CLI (`browser_exec`, needs `uvx browser-use`, not in image) -> set `browser.backend: "off"` to get `browser_navigate` etc. Those shell out to `npx agent-browser@^0.26.0`, which is NOT in the image: every first use downloads it from registry.npmjs.org, and **each npx call POSTs `registry.npmjs.org/-/npm/v1/security/advisories/bulk`** (npm audit; extra cards, and sends the package list). Denied -> "Chrome not found / agent-browser ..." after 30 s. agent-browser then can't find the image's Playwright `chromium_headless_shell-1243` (looks for `chromium-*`), so `AGENT_BROWSER_EXECUTABLE_PATH` must point at `/opt/hermes/.playwright/chromium_headless_shell-1243/chrome-headless-shell-linux64/chrome-headless-shell`. With that + the NSS db, Hermes' `browser_navigate https://example.com/` succeeded (15 s, mostly npx). Cards: `GET https://example.com/` and `GET https://example.com/s.js` (every subresource is its own card, so card fatigue on real sites) plus npm audit cards.
- **web_search / web_extract**: no direct fetch. With no keys Hermes uses keyless third-party backends: `GET https://api.keenable.ai/v1/fetch/public?url=<target>`, `POST https://api.firecrawl.dev/v2/scrape`, `POST https://api.keenable.ai/v1/search/public`. They honored proxy and CA; extract returned example.com content. But the approval card names the vendor API, not the page (target is in a query string / POST body), and a standing allow for those hosts lets the agent fetch ANY URL via the vendor. One keenable fetch returned `[error]` once, the next (firecrawl) succeeded; not investigated. Keyed backends (Firecrawl/Tavily/Exa/SearXNG) would need keys swapped at the proxy the same way.

## Hosts Hermes contacted with no allow rules (cards seen)
Idle container (s6 services, 100 s fresh volume): **none**. `hermes gateway run` (API server on) for 60 s: nothing extra beyond below.
On first `hermes chat` / gateway start:
- `models.dev/api.json` (model catalog; before a provider is set; ~15 s retry loop)
- `github.com/.../releases/latest/download/*.tar.gz` (tirith security scanner download; it then stays "not available"; path redacted by the proxy)
- `pypi.org/simple/edge-tts/` (+ files.pythonhosted.org if allowed): lazy install of `edge-tts` for TTS on EVERY start until it succeeds, although the image sets `HERMES_DISABLE_LAZY_INSTALLS=1`; twice per run
- `http://169.254.169.254/latest/api/token` (cloud IMDS probe; hard-denied by the SSRF guard, never a card)
- custom-provider probes: `GET /v1/models`, `GET /models`, `POST /api/show` on the model host
- on browser use: `registry.npmjs.org` (package metadata + audit POST)
- web tools: `api.keenable.ai`, `api.firecrawl.dev`
No telemetry/update-check hosts observed in these runs (only `hermes chat` and `gateway run` exercised, not `hermes update`, dashboard, or messaging platforms).

## Verdict
Viable, with changes:
1. Env: set BOTH `SSL_CERT_FILE` and `REQUESTS_CA_BUNDLE`, plus `NODE_EXTRA_CA_CERTS` + `NODE_USE_ENV_PROXY=1`, and the CA in the system store.
2. Bake into a derived image: `libnss3-tools` + NSS db in `/opt/data/home/.pki/nssdb` (created at boot after the CA appears), `agent-browser` preinstalled (avoid npm + audit POSTs), `AGENT_BROWSER_EXECUTABLE_PATH`, `edge-tts` (or disable TTS) and tirith so no startup downloads need approval.
3. Pre-approve (always-allow) the model host so the 3-4 serial probes plus chat don't each cost a human approval; keep per-call approval windows under ~3 min or raise Hermes' stream stale timeout.
4. Treat web_search/web_extract as "send data to vendor"; decide whether to allow those vendor hosts or force the browser/terminal path (which shows the real URL).
5. Credential swap works as designed for `Authorization: Bearer`; other auth styles (x-api-key, query params, SigV4 signing) not tried.
Not verified: real TLS providers (Anthropic/OpenRouter/Nous portal OAuth), Nous managed tool gateway, messaging gateways (Telegram/Discord websockets), dashboard, `hermes update`, the Docker/SSH/Modal terminal backends (sibling-container bypass is exactly as the egress-proxy README warns), ACP mode, cap_drop/read-only hardening of the Hermes container (it ran as stock root->hermes s6 image with default caps), arm64, and HTTP/3. My `allow_once` runs let Hermes install PyPI/npm packages from the real internet, which is the behavior a real approver would see.

# Prototypes

Throwaway spikes for a self-hosted, Muse-style agent built on
[Hermes Agent](https://github.com/NousResearch/hermes-agent). Each directory has its own README
with how to run it, captured output, findings and gaps.

| Dir | What it explores |
|---|---|
| [egress-proxy](./egress-proxy) | TLS-intercepting proxy that holds requests to unlisted URLs for Allow / Always allow / Deny approval; sandbox network has no other route out |
| [hermes-acp-spike](./hermes-acp-spike) | Driving `hermes acp` over stdio (no listener) plus an outbound-dialling bridge |
| [hermes-plugin-spike](./hermes-plugin-spike) | Custom Hermes platform plugin that dials out to a trusted-side socket |
| [hermes-through-proxy](./hermes-through-proxy) | Hermes inside the egress-proxy sandbox: CA trust, model calls, browser tool, credential swap |

## Caveats

- The spikes were run against Hermes v0.21.5 (the `latest` image at the time) with a mock LLM and
  fake keys. Image refs are now pinned to `v0.22.5` (the closest published versioned tag) per the
  repo's image-pinning rule, and the spikes have **not** been re-run on it. Expect small drift,
  especially in the plugin spike (the plugin API is undocumented and unstable).
- `egress-proxy` passes its own `./test.sh` (37 checks). The other spikes are manual runs with
  captured output, not automated tests.
- Prototype quality: the approval API has no auth beyond network separation. See each README's
  "known gaps".

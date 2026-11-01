# AdGuard Home: keeping local names up when the internet is down

Issue: [#1](https://github.com/nathan815/homelab/issues/1). Config: `stacks/adguardhome/AdGuardHome.yaml`.

## The problem

AdGuard handles at most `max_goroutines` requests at once (default 300), local names included. The UDP listener waits for a free slot before it reads the next packet, so once the slots are full every query times out, including rewrites like `hass.lan` that need no upstream.

With the internet down, an uncached external query holds its slot for 10–30 s before it returns SERVFAIL, no matter what `upstream_timeout` is set to:

- Bootstrap lookups of the upstream hostnames use a fixed 10 s timeout. AdGuard builds the bootstrap resolver with `DefaultTimeout`, not the configured value.
- Stale keep-alive connections to the upstreams time out, then each resolved address is redialed.
- `fallback_dns` is then tried twice, `upstream_timeout` each (~6 s).

So in-flight requests ≈ query rate × ~20 s, and 300 slots fill at about 15 qps.

## Settings

| Setting | Value | Why |
|---|---|---|
| `max_goroutines` | 2000 | Room for ~50 qps of dead-upstream traffic. 0 (unlimited) also works, but its memory is unbounded |
| `upstream_timeout` | 3s (was 10s) | Per-attempt timeout; healthy upstreams answer in <300 ms. Cuts a dead-upstream hang from ~30 s to ~20 s, not to 3 s |
| `cache_optimistic` | true | Names seen in the last 12 h (`cache_optimistic_max_age` default) answer from cache during an outage and never take a slot |

Rewrites already answer every query type (A, AAAA, HTTPS, TXT, …) for `*.lan` and `*.lan.nathancj.com` locally, so no extra filtering rules are needed.

## Test results

Test setup: AdGuard v0.107.79 in local Docker. The outage is simulated by routing the container's default gateway to a container that silently drops packets. (An iptables DROP in the container's own OUTPUT chain fails instantly with EPERM and doesn't reproduce a dead WAN.) The background load is unique external names. Local names are probed every 0.25 s with a 2 s timeout.

| Config | Offline 10 qps | Offline 50 qps | Offline 150–200 qps | Memory |
|---|---|---|---|---|
| 300 slots, 10s (old default) | 34% local timeouts | 93% local timeouts | – | – |
| 300 slots, 3s | 0% | 93% local timeouts | – | – |
| 0 (unlimited), 10s | 0% | 0% | 0% at 200 qps | ~520 MB at 200 qps |
| **2000 slots, 3s, optimistic cache** | – | **0%, ~1 ms** | 15% timeouts at 150 qps | 118 MB at 50 qps |

Online at 100–200 qps, every config answered local names in 1–2 ms (p50).

## Deploying config changes

The container mounts `./data/config`, so the live file is `data/config/AdGuardHome.yaml` on pi01, not the repo copy. The repo copy has credential placeholders, so don't copy it over the live file. Back up the live file, `docker compose stop adguardhome`, edit the keys, then `docker compose start adguardhome`. AdGuard rewrites the file (and drops comments) on UI changes and upgrades.

## Upstream

- Bootstrap timeout: `AdGuardHome/internal/dnsforward/dnsforward.go` creates the bootstrap resolver with `Timeout: DefaultTimeout` (10 s).
- Slot limit blocks the reader: `dnsproxy/proxy/serverudp.go` acquires the semaphore in the UDP read loop before spawning the handler.
- Related upstream issue: AdguardTeam/AdGuardHome#4317.

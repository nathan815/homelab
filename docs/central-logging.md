# Central logging (Loki + Grafana + Alloy)

Container and journal logs from every Docker host are shipped to Loki on pi01 and queried in Grafana (`Explore` -> datasource **Loki**). Logs outlive container recreation and stack redeploys (issue #55).

| Piece | Where | Notes |
|---|---|---|
| Loki | `stacks/loki` on docker.lan (Komodo server `docker-main`) | Port 3100, config `stacks/loki/loki.yml` |
| Alloy | `stacks/alloy`, one per host | Komodo stacks `alloy_pi01`, `alloy_docker-main`; Ansible (`base.yml`, tag `alloy`) on octoprint |
| Grafana | existing on pi01, `Loki` datasource provisioned | `stacks/monitoring/grafana/datasource.yml` |

## Storage and retention
- Retention: **30 days** (`limits_config.retention_period: 720h`, enforced by the compactor). The issue asked for 30-90; start low and raise it once you've measured. Loki cannot cap by size, only by age.
- Data: `/mnt/disk2/monitoring-data/loki` on docker.lan (3.6T HDD, 2.9T free), outside the Komodo clone, so redeploys keep it. Not backed up. Why not pi01: its storage is small, and flash (SD card, USB stick) wears out under Loki's constant writes.
- Footprint: unmeasured. After a week, `du -sh /mnt/disk2/monitoring-data/loki` on docker.lan; steady state is about (size after 7 days / 7) x retention days. Loki compresses well (typically 5-10x), so a homelab is usually well under 5G for 30 days.
- Volume controls: Alloy drops journal info/debug entries, healthcheck/metrics lines and the logging stack's own logs; Loki rate-limits ingestion (2MB/s, 1MB/s per stream) so a crash-looping container can't fill the disk.

## Labels
`host` (pi01, docker-main, octoprint), `source` (`docker` / `journal`), `container`, `stack`, `service`, `unit` (journal).

Example: public proxy access logs, last 24h: `{host="pi01", container="nginx-public"}`.

## nginx-public
- Access log line starts with `$http_cf_connecting_ip` (the real client; `$remote_addr` is the tunnel), and ends with `xff=`.
- `access_token=` in query strings is replaced with `REDACTED` by nginx before logging. Each public server block sets its own `access_log` because the stock `nginx.conf` logs the raw URI at `http` level. A new server block must do the same (copy an existing one).
- Alloy also redacts `access_token=` and `Authorization:` values as a backstop.

## Rollout
1. On docker.lan: `sudo mkdir -p /mnt/disk2/monitoring-data/loki`.
2. Apply the Komodo sync (adds `loki`, `alloy_pi01`, `alloy_docker-main`), deploy `loki` first, then both Alloys. Redeploy `monitoring` so Grafana picks up the datasource.
3. `ansible-playbook playbooks/base.yml --tags alloy --limit octoprint`.
4. Recreate `nginx-proxy` to pick up the log format.

Alloy reaches Loki at `http://docker.lan:3100`; there is no auth, LAN only. Only the logs from deploy time onward exist; nothing is back-filled.

## Not done
Alert rules for suspicious requests on public vhosts (optional in the issue).

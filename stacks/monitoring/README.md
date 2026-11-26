# monitoring (pi01)

Prometheus, Alertmanager, Grafana, Uptime Kuma, and the blackbox/speedtest exporters.
Deployed by Komodo from `main` (`komodo/komodo.toml`, stack `monitoring`).

| Service | Port on pi01 | Data |
|---|---|---|
| Prometheus | 3001 (`prometheus.lan.nathancj.com`) | `/mnt/data1/monitoring-data/prometheus` (USB stick) |
| Alertmanager | 9093 | `alertmanager_data` volume (SD card) |
| Grafana | 3000 | `monitoring_grafana_data` volume |
| Uptime Kuma | 3002 | `/opt/appdata/monitoring/uptime-kuma` (SD card) |

## Alerting

```
Prometheus rules (prometheus/alerts.yml)
  └─> Alertmanager (alertmanager/alertmanager.yml)
        ├─ severity=critical  -> Discord + Pushover
        ├─ severity=warning   -> Discord
        └─ Watchdog heartbeat -> healthchecks.io ping, every minute
                                   └─ no ping for 5 min -> healthchecks.io alerts you
```

The heartbeat is the part that covers what Prometheus can't report on itself:
Prometheus or Alertmanager down, pi01 down, the LAN or the internet down, a power cut.
Uptime Kuma separately watches the services, with its own Discord/Pushover notifications.

What the rules catch (each has a test in `prometheus/alerts_test.yml`):

| Alert | Severity | Fires when |
|---|---|---|
| `FilesystemReadOnly` | critical | any ext4/xfs/btrfs/vfat mount on a scraped host has gone read-only (1 min) |
| `PrometheusTsdbWriteFailures` | critical | WAL writes, compactions, checkpoints or head truncation fail |
| `PrometheusNotIngesting` | critical | no new samples stored for 5 min |
| `FilesystemAlmostFull` | warning | under 2 GiB free (15 min) |
| `FilesystemFillingUp` | warning | under 10% free and on course to fill within 24 h |
| `TargetDown` | warning | a scrape target down for 10 min |
| `PrometheusRuleEvaluationFailures`, `PrometheusNotificationsFailing`, `AlertmanagerNotificationsFailing` | warning | the alerting pipeline itself is erroring |

`FilesystemReadOnly` suppresses the two Prometheus write alerts, since a read-only
disk causes both.

**Why this exists:** on 2026-11-14 pi01's `/mnt/data1` USB stick locked itself
read-only. Prometheus kept answering HTTP and reported healthy while saving nothing,
and Uptime Kuma, whose data was on the same stick, went down with it. Nothing alerted,
and 12 days of metrics were lost.

### Secrets

Komodo secret variables (Settings -> Variables), passed to Alertmanager as Docker secrets:

| Variable | Value |
|---|---|
| `ALERTMANAGER_DISCORD_WEBHOOK_URL` | a Discord channel webhook URL (Uptime Kuma's `#alerts` webhook works) |
| `ALERTMANAGER_PUSHOVER_USER_KEY` | your Pushover user key |
| `ALERTMANAGER_PUSHOVER_TOKEN` | a Pushover application token (e.g. a new "Alertmanager" app) |
| `ALERTMANAGER_HEALTHCHECKS_PING_URL` | the check's ping URL, `https://hc-ping.com/<uuid>` |

### healthchecks.io check

Create one check: **Period 1 minute, Grace 5 minutes**, and add the notification
integrations you want on the healthchecks.io side (email, Pushover, Discord...).
Alertmanager pings it every minute with the always-firing `Watchdog` alert.

### Test it

- Rules: `bash stacks/monitoring/validate.sh` (also runs in CI).
- Delivery, from pi01, sends a test critical alert:
  ```bash
  docker exec alertmanager amtool alert add TestAlert severity=critical instance=manual --annotation=summary="Test alert, ignore" --alertmanager.url=http://localhost:9093
  ```
- Heartbeat: `docker stop alertmanager`; healthchecks.io should alert about 5 minutes later.
  Then `docker start alertmanager`.

## Moving Uptime Kuma's data off the USB stick (one-time, before deploying this change)

Uptime Kuma used to live on `/mnt/data1` next to Prometheus. This compose file points
it at `/opt/appdata/monitoring/uptime-kuma` on the SD card instead. Copy the data
there **before** Komodo deploys the change, or Kuma starts with an empty database.
On pi01:

```bash
docker stop monitoring-uptime-kuma-1
sudo mkdir -p /opt/appdata/monitoring
sudo rsync -aHAX /mnt/data1/monitoring-data/uptime-kuma/ /opt/appdata/monitoring/uptime-kuma/
```

Then deploy. The old copy stays on `/mnt/data1` as the rollback. If the deploy ran
first and Kuma came up empty: stop it, run the `rsync` above, and start it again.

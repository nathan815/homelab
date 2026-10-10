# Komodo GitOps

`komodo.toml` declares the servers and stacks Komodo manages. Compose files stay in `stacks/<name>/`.

## One-time setup (Komodo UI, http://komodo.lan.nathancj.com)

1. **Git access**: none needed, the repo is public. If it ever goes private, add a GitHub account under Settings -> Providers and set `git_account` on the stacks and sync.
2. **Periphery** runs on each host as `komodo-periphery` in the `container-mgmt` stack (deployed by `ansible/playbooks/base.yml`, image pinned to `ghcr.io/mbecker20/periphery:1.16`, port 8120, auth via `KOMODO_PASSKEY`). Confirm the `pi01` server shows as connected in Komodo before syncing. Note Periphery's `PERIPHERY_STACK_DIR` is `/opt/stacks`, the same directory Ansible's `deploy-stack` role and Dockge use: check where Komodo writes a git-backed stack before migrating one, so the two don't fight over `/opt/stacks/<name>`.
3. **The `homelab` sync already exists** in Komodo (repo `nathan815/homelab`, path `komodo/komodo.toml`) and is deliberately not in `komodo.toml`, because a sync can't update its own resource while running ("resource busy"). Its config is recorded in `komodo/bootstrap.toml` (not read by the sync) so a fresh Komodo can recreate it. To test from a branch, set the sync's branch in the UI; set it back to `main` after merging. `komodo.toml` was seeded from the live config, so Refresh should show only new/changed resources. **Check the Pending tab before Execute**, especially for deletions.
4. **API key for CI**: Settings -> API keys -> create one. Add it to Woodpecker as repo secrets `komodo_api_key` and `komodo_api_secret`.
5. **Woodpecker** (push events only): in the repo's settings turn OFF "Allow pull requests" (public repo, self-hosted agent). GitHub must be able to reach Woodpecker's `/api/hook` for the `deployment` event, so a public route to just that path is required (not set up yet).
6. **ghcr.io package**: after the first `lanindex` workflow run, set the package visibility to public so pi01 can pull without credentials.
7. Optional: add a GitHub webhook to `/listener/github/sync/homelab/sync` so toml edits apply on push.

## Migrating a stack
Komodo clones git-backed stacks into `/opt/stacks/<stack>` on the host, the same directory Ansible's `deploy-stack` role copies to. Neither tool can use the folder while the other's copy is there (a plain-files folder makes Komodo fail with "not a git repository" / "Failed to write / clone compose file"). **Stacks with runtime data in the stack folder (relative `./data/...` mounts: `media-system`, `adguardhome`, `container-mgmt`, `dashkiosk`, `upsnap`, `viewtube`) must NOT be migrated this way yet.** Moving the folder aside takes the data with it, and the service would start empty; in git mode the folder is also Komodo's to re-clone. Move the data to a host path outside `/opt/stacks` first (tracked in #9). `lanindex` has no volumes and is safe. Per stack:
0. Check the stack's compose file for relative `./data` mounts; if any, do #9 for it first.
1. Add a `[[stack]]` block (git mode) and sync.
2. Remove the stack from `ansible/playbooks/*.yml` so Ansible stops writing to it.
3. On the host, move the Ansible-copied folder aside: `sudo mv /opt/stacks/<stack> /opt/stacks/<stack>.ansible-bak` (the running containers are unaffected).
4. Redeploy from Komodo, confirm, then delete the `.ansible-bak` folder.

### monitoring (one-off, #7)
Was the `monitoring-server` Ansible role (rendered into `~/monitoring`, compose project `monitoring`). Data lives outside the stack folder: Prometheus in `/mnt/data1/monitoring-data/prometheus`, Grafana in the named volume `monitoring_grafana_data` (pinned in the compose file). Uptime Kuma used to live in `/opt/stacks/monitoring/uptimekuma_data`, which is now Komodo's clone target, so it moves. On pi01:
1. Back up: `sudo tar czf ~/monitoring-backup.tgz /opt/stacks/monitoring /mnt/data1/monitoring-data` and `docker run --rm -v monitoring_grafana_data:/v -v ~/:/b alpine tar czf /b/grafana_data.tgz -C /v .`
2. In Komodo, Settings -> Variables: add secret variables `GRAFANA_ADMIN_PASSWORD` (only used if Grafana's DB is ever recreated) and `HOME_ASSISTANT_TOKEN` (same value as `secrets.home_assistant_token` in Ansible).
3. `cd ~/monitoring && docker compose down`, then `sudo mkdir -p /mnt/data1/monitoring-data && sudo mv /opt/stacks/monitoring/uptimekuma_data /mnt/data1/monitoring-data/uptime-kuma` and `sudo mv /opt/stacks/monitoring /opt/stacks/monitoring.ansible-bak`.
4. Sync, then Deploy `monitoring` in Komodo. Check Grafana dashboards, Prometheus targets (incl. `homeassistant_sensors`) and Uptime Kuma monitors, then delete `~/monitoring` and the `.ansible-bak` folder.

## Flow (lanindex)
push to main -> GitHub Actions builds arm64 image, pushes `ghcr.io/nathan815/lanindex` -> creates a GitHub deployment -> Woodpecker (`.woodpecker/deploy-lanindex.yaml`, deployment event) -> Komodo `DeployStack` (the step polls the update until it completes and fails if it didn't succeed) -> pi01 pulls and restarts.
The `lanindex` workflow runs `validate.yml` first (`needs: validate`), so a failing check blocks the image push and the deployment.
PRs run `.github/workflows/validate.yml` only (GitHub-hosted, no secrets).

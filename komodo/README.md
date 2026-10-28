# Komodo GitOps

`komodo.toml` declares the servers and stacks Komodo manages. Compose files stay in `stacks/<name>/`.

## One-time setup (Komodo UI, http://komodo.lan.nathancj.com)

1. **Git access**: none needed, the repo is public. If it ever goes private, add a GitHub account under Settings -> Providers and set `git_account` on the stacks and sync.
2. **Periphery** runs on each host as `komodo-periphery` in the `container-mgmt` stack (deployed by `ansible/playbooks/base.yml`, image pinned to `ghcr.io/mbecker20/periphery:1.16`, port 8120, auth via `KOMODO_PASSKEY`). Confirm the `pi01` server shows as connected in Komodo before syncing. Note Periphery's `PERIPHERY_STACK_DIR` is `/opt/stacks`, the same directory Ansible's `deploy-stack` role and Dockge use: check where Komodo writes a git-backed stack before migrating one, so the two don't fight over `/opt/stacks/<name>`.
3. **The `homelab` sync already exists** in Komodo (repo `nathan815/homelab`, path `komodo/komodo.toml`) and is deliberately not in `komodo.toml`, because a sync can't update its own resource while running ("resource busy"). Its config is recorded in `komodo/bootstrap.toml` (not read by the sync) so a fresh Komodo can recreate it. To test from a branch, set the sync's branch in the UI; set it back to `main` after merging. `komodo.toml` was seeded from the live config, so Refresh should show only new/changed resources. **Check the Pending tab before Execute**, especially for deletions.
4. **API key for CI**: Settings -> API keys -> create one (the dialog shows a key `K-...` and a secret `S-...`; the secret is shown only once), **on an admin user** (CI sets Komodo variables, and `UpdateVariableValue` is admin only). Add it to Woodpecker as repo secrets `komodo_api_key` and `komodo_api_secret`, limited to the `deployment` event. Keep the repo non-Trusted in Woodpecker.
   Leave the `homelab` sync's "include variables" off: CI owns the `<STACK>_IMAGE_TAG` variables.
5. **Woodpecker** (push events only): in the repo's settings turn OFF "Allow pull requests" (public repo, self-hosted agent). GitHub reaches Woodpecker's `/api/hook` for the `deployment` event via `https://ci-hooks.nathancj.com` (cloudflared tunnel -> `nginx-public`, which forwards only POST `/api/hook`).
6. **ghcr.io packages**: after the first deploy of a stack with an `apps/<name>/` image, set the `<name>` package visibility to public so the host can pull without credentials.
7. Optional: add a GitHub webhook to `/listener/github/sync/homelab/sync` so toml edits apply on push.

## Migrating a stack
Komodo clones git-backed stacks into `/opt/stacks/<stack>` on the host, the same directory Ansible's `deploy-stack` role copies to. Neither tool can use the folder while the other's copy is there (a plain-files folder makes Komodo fail with "not a git repository" / "Failed to write / clone compose file"). **Stacks with runtime data in the stack folder (relative `./data/...` mounts: `media-system`, `adguardhome`, `container-mgmt`, `dashkiosk`, `upsnap`, `viewtube`) must NOT be migrated this way yet.** Moving the folder aside takes the data with it, and the service would start empty; in git mode the folder is also Komodo's to re-clone. Move the data to a host path outside `/opt/stacks` first (tracked in #9). `lanindex` has no volumes and is safe. Per stack:
0. Check the stack's compose file for relative `./data` mounts. If it has any, change them to `${APPDATA_DIR:-/opt/appdata}/<stack>/...` and move the data on the host first, following `docs/appdata-migration.md` (#9): `stacks/migrate-appdata.sh <stack>` on the host copies `./data/` to `/opt/appdata/<stack>/`, verifies it and keeps `./data.pre-appdata` as the rollback copy. Then deploy with Ansible `--tags <stack>` and verify. Do the data move and that deploy together. Ansible's `deploy-stack` refuses to deploy a stack that mounts `APPDATA_DIR` while `/opt/stacks/<stack>/data` still exists, because it would start on empty data.
1. Add a `[[stack]]` block (git mode) and sync.
2. Remove the stack from `ansible/playbooks/*.yml` so Ansible stops writing to it.
3. On the host, move the Ansible-copied folder aside: `sudo mv /opt/stacks/<stack> /opt/stacks/<stack>.ansible-bak` (the running containers are unaffected).
4. Redeploy from Komodo, confirm, then delete the `.ansible-bak` folder.

### monitoring (one-off, #7)
Was the `monitoring-server` Ansible role (`~/monitoring`, compose project `monitoring`). Only Uptime Kuma's data moves: it lived in `/opt/stacks/monitoring/uptimekuma_data`, which Komodo now clones into, and goes to `/mnt/data1/monitoring-data/uptime-kuma`. Prometheus (`/mnt/data1/monitoring-data/prometheus`) and Grafana (volume `monitoring_grafana_data`) stay put. Merging the PR triggers `deploy:monitoring`, which fails until the cutover is done; a failed deploy leaves the running containers alone.
1. In Komodo, Settings -> Variables: add secret variables `GRAFANA_ADMIN_PASSWORD` (only used if Grafana's DB is ever recreated) and `HOME_ASSISTANT_TOKEN` (same value as `secrets.home_assistant_token` in Ansible).
2. Merge, then on pi01 run `sudo sh stacks/monitoring/cutover.sh` (from a checkout, or copy the file over). It checks nothing will be overwritten, backs up the Uptime Kuma data, stops the old containers, moves the data and moves `/opt/stacks/monitoring` to `.ansible-bak`. Monitoring is down until step 3.
3. Run the `homelab` sync, then deploy `monitoring`. The script prints these steps, what to check and how to roll back.

## Deploy flow
push to main -> `.github/workflows/deploy.yml`:
1. runs `validate.yml` (`needs`) on the ref being deployed, so a failing check blocks every build and deploy;
2. finds the stacks whose `stacks/<name>/` or `apps/<name>/` changed, keeping only git-backed stacks in `komodo.toml` (`.github/scripts/deploy_plan.py`). If the previous commit is unknown (new branch, force push) it deploys all of them;
3. one matrix job per stack (concurrency group per stack): if `apps/<name>/Dockerfile` exists, builds arm64 on `ubuntu-24.04-arm` and pushes `ghcr.io/nathan815/<name>:<sha>` (and `:latest`); then creates a GitHub deployment with task `deploy:<name>`.

Woodpecker (`.woodpecker/deploy.yaml`, deployment events whose task starts with `deploy:`) runs `ci/komodo-deploy.sh`: for stacks with an image it sets the Komodo variable `<NAME>_IMAGE_TAG` (uppercase, `-` -> `_`) to the sha, then calls `DeployStack` and polls the update, failing unless it succeeded.

Images are pinned to the commit sha: the stack's `environment` in `komodo.toml` has `IMAGE_TAG = [[<NAME>_IMAGE_TAG]]` and the compose file uses `image: ...:${IMAGE_TAG:-latest}`. Komodo needs the variable to exist before the stack can deploy: CI creates it on the first deploy, or create it once by hand (Settings -> Variables, value `latest`).

**Manual deploy / rollback**: Actions -> Deploy -> Run workflow with a stack and a ref (branch, tag or sha). It builds the image for that sha if it isn't already in ghcr.io, then deploys it. Rolling back = dispatching an older sha. Komodo always reads compose files from `main`, so a branch dispatch changes the image, not the compose file.

PRs run `.github/workflows/validate.yml` only (GitHub-hosted, no secrets).

## Adding a stack
1. `stacks/<name>/docker-compose.yml`, plus `apps/<name>/Dockerfile` if it's built here (image `ghcr.io/nathan815/<name>:${IMAGE_TAG:-latest}`). Third-party images need no `apps/` folder.
2. A git-backed `[[stack]]` block in `komodo.toml` named `<name>` with `run_directory = "stacks/<name>"` (copy `lanindex`). For a built image add `IMAGE_TAG = [[<NAME>_IMAGE_TAG]]` to its `environment`.
3. Sync, then push. If the stack existed under Ansible, follow "Migrating a stack" first.

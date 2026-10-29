# Komodo GitOps

Komodo v2 (Core 2.3.4) manages the stacks declared in `komodo.toml`. Compose files stay in `stacks/<name>/`.

| Piece | Where | Deployed by |
|---|---|---|
| Core + FerretDB v2 + Postgres/DocumentDB | `stacks/komodo`, pi01, port 9120 (`http://komodo.lan.nathancj.com`) | Ansible `core-services.yml --tags komodo` (never Komodo itself) |
| Periphery agent | `stacks/komodo-periphery`, every host in the `komodo-servers` inventory group (pi01, docker.lan) | Ansible `base.yml --tags komodo-periphery` (never Komodo itself) |
| Servers, stacks, procedures | `komodo/komodo.toml` | the `homelab` resource sync |
| The sync itself | `komodo/bootstrap.toml` (record only) | created once by hand in the UI |

Periphery runs in **outbound mode**: each agent dials `ws://pi01.lan:9120`, so hosts no longer expose port 8120. Core and Periphery authenticate with key pairs (v2), not the v1 passkey. A new agent joins with a one-time **onboarding key** (Settings -> Onboarding). After that its private key (the `keys` volume) is what identifies it, and it pins Core's public key on first connect. Keep the `komodo-core` and `komodo-periphery` image versions the same.

## Folder ownership (decision for #6, unblocks #9)

Each host directory has exactly one owner:

| Path on host | Owner | Contents |
|---|---|---|
| `/opt/stacks/<name>` | **Ansible** (`deploy-stack` role) | Compose folders copied from `stacks/<name>`, plus the host's `.env`. Komodo `files_on_host` stacks run from here but never write here. Dockge reads this tree until it is retired. |
| `/opt/komodo/stacks/<name>` | **Komodo** (Periphery root `/opt/komodo`) | Git-backed stacks: Komodo clones the whole repo here and runs `stacks/<name>` inside it. Disposable: Komodo may delete and re-clone it. |
| `/opt/appdata/<name>` | **Neither tool**: the stack's runtime data | Bind mounts for state (databases, app config written at runtime). Never copied, cloned or deleted by a deploy. |

Where Komodo v2 writes (checked in Periphery v2.3.4 `stack/write.rs`):
- **Git-backed stack**: `<stack_dir>/<stack name>/<clone_path>` holds the clone, and compose runs in `<clone>/<run_directory>`. With `PERIPHERY_ROOT_DIRECTORY=/opt/komodo`, `lanindex` is cloned to `/opt/komodo/stacks/lanindex` and runs from `/opt/komodo/stacks/lanindex/stacks/lanindex`.
- **`files_on_host` stack**: compose runs in `<stack_dir>/<stack name>/<run_directory>`, so a relative `run_directory` lands under `/opt/komodo/stacks/`. Every `files_on_host` stack in `komodo.toml` therefore sets an **absolute** `run_directory = "/opt/stacks/<name>"`.

So Ansible and Komodo no longer share a folder, and v1's "not a git repository" clash is gone. A relative `./data` mount still breaks git mode, though: it would resolve inside the clone (`/opt/komodo/stacks/<name>/stacks/<name>/data`), which Komodo may wipe. **Rule for #9:** runtime data goes in `/opt/appdata/<stack>/...` (small state on the host's root disk). Bulk data stays on explicit data disks (`/mnt/data1/...`, `/mnt/disk*`, as `monitoring` and `media-system` already do). Read-only config files committed to git (e.g. `./prometheus`) may stay relative. `base.yml` creates `/opt/komodo` and `/opt/appdata` on Komodo hosts.

## Values you must supply (not in git)

| Value | Where it goes | Notes |
|---|---|---|
| `KOMODO_DATABASE_USERNAME`, `KOMODO_DATABASE_PASSWORD` | pi01 `/opt/stacks/komodo/.env` | New. Postgres is initialised with these on first start. Password: `openssl rand -hex 24`. |
| `KOMODO_JWT_SECRET`, `KOMODO_WEBHOOK_SECRET` | same `.env` | `openssl rand -hex 32` each. Reusing the v1 values is fine. |
| `KOMODO_INIT_ADMIN_USERNAME`, `KOMODO_INIT_ADMIN_PASSWORD` | same `.env` | Creates the first admin on an empty DB only. Change the password in the UI afterwards. |
| Onboarding key `O-...` | `-e komodo_onboarding_key=...` on the first `base.yml` run per host | Create in the UI (Settings -> Onboarding). Disable it once all hosts are connected. |
| Komodo variables `LANINDEX_IMAGE_TAG`, `GRAFANA_ADMIN_PASSWORD` (secret), `HOME_ASSISTANT_TOKEN` (secret) | Komodo UI, Settings -> Variables | `LANINDEX_IMAGE_TAG` = the sha currently running (see runbook step 6). `HOME_ASSISTANT_TOKEN` = `secrets.home_assistant_token` from Ansible. |
| CI API key + secret | Woodpecker repo secrets `komodo_api_key`, `komodo_api_secret` (event `deployment` only) | New key on an **admin** user. The v1 key stops working at cutover. |
| Anything else from the v1 export | Komodo UI | Alerters, extra users, provider accounts: see runbook step 0. |

## Rollout runbook (v1.16.12 -> v2)

Each step changes one thing and has its own rollback. Do them in order, and stop at the first surprise. Run commands on pi01 unless noted. Ansible commands run from `ansible/` in a checkout of `main` that includes this change.

Merging this PR deploys nothing by itself: `deploy.yml` only deploys git-backed stacks, and this PR touches only `komodo`, `komodo-periphery` and `container-mgmt`, which are Ansible-deployed. Even so, merge only when you are ready to run the steps below, because the next `base.yml` / `core-services.yml` run will apply the change. Until step 6 is done, CI deploys of `lanindex` / `monitoring` will fail (the old API key is gone). A failed deploy leaves running containers alone.

**0. Inventory v1 (read-only).** In the v1 UI (`http://pi01.lan:9120`): open Syncs -> `homelab`, or any resource's "Export TOML", and save the full export somewhere outside git. Diff it against `komodo.toml` (seeded from the live config on 2026-10-09). Also write down: Settings -> Variables (names and values), Alerters, Users, API keys, and git/registry provider accounts. Anything worth keeping that isn't in `komodo.toml` gets re-created by hand in step 6, or added to `komodo.toml`. This PR intentionally drops `test-komodo-stack`, the `test` deployment and the empty `local` builder. Generate the secrets in the table above.
*Rollback: nothing changed.*

**1–2. Back up v1 and cut Core over: `stacks/komodo/cutover.sh`** (Komodo is down from here until the Ansible run below finishes; running stacks and the v1 agents are unaffected):
```bash
scp stacks/komodo/cutover.sh pi01.lan:
ssh -t pi01.lan sudo sh cutover.sh
```
It refuses to run unless `/opt/stacks/komodo` still has the v1 compose file, the `komodo_sqlite-data` volume exists and `/opt/appdata/komodo/v1-backup` doesn't. It shows the plan and asks first, then:
- stops v1 with its own compose file (`docker compose down`, volumes kept);
- tars `komodo_sqlite-data` to `/opt/appdata/komodo/v1-backup/sqlite-data.tgz` and copies the stack folder (v1 compose file, `.env`) to `v1-backup/stack-folder`;
- writes the v2 `.env`: generated Postgres user/password, the v1 JWT and webhook secrets carried over (or generated), and the init admin you type in.

Then, from your laptop: `./ansible_playbook.sh playbooks/core-services.yml --limit pi01 --tags komodo`. This copies the new compose file and runs `up -d`. The old `komodo.env` stays on the host, unused.
Check: `docker compose ps` (postgres, ferretdb, core all up), `docker compose logs core | tail -50` (no DB errors). Log in at `http://komodo.lan.nathancj.com` with the init admin, then change its password and blank `KOMODO_INIT_ADMIN_PASSWORD` in `.env`. Optionally enable 2FA (user menu).
*Rollback: `ssh -t pi01.lan sudo sh cutover.sh rollback`. It runs `docker compose down` on the new stack (keeping its volumes), copies `v1-backup/stack-folder` back and starts v1 on the untouched `komodo_sqlite-data` volume. v1 agents still run on the hosts, so v1 is fully back. Avoid re-running Ansible's `komodo` tag from `main` until you are ready again.*

**3. Onboarding key.** UI -> Settings -> Onboarding -> create a key (privileged mode not needed, the servers don't exist yet). Copy the `O-...` value; it is shown once.
*Rollback: delete the key.*

**4. Periphery, one host at a time** (pi01 first, then docker.lan). The new container has the same name as the v1 agent, so remove the v1 agent first. Only the agent stops; the containers it manages keep running.
```bash
ssh pi01.lan 'docker stop komodo-periphery && docker rm komodo-periphery'   # v1 agent (orphan of container-mgmt)
read -rs KOMODO_OK                                  # paste O-... (keeps it out of shell history)
./ansible_playbook.sh playbooks/base.yml --limit pi01 --tags container-mgmt,komodo-periphery \
  -e komodo_onboarding_key="$KOMODO_OK"
```
Check: `docker logs komodo-periphery` shows it connected, and UI -> Servers shows `pi01` OK. Repeat with `--limit docker.lan`; that host joins as `docker-main` via `komodo_server_name` in the inventory. **octoprint** is not a Komodo server: it is 32-bit Raspbian (`armhf`) and Periphery v2 ships only amd64/arm64. It had no v1 agent either, so nothing to do there. After all hosts are connected, disable or delete the onboarding key in the UI, and remove the `KOMODO_ONBOARDING_KEY=` line from `/opt/stacks/komodo-periphery/.env` on each host.
*Rollback (per host): `cd /opt/stacks/komodo-periphery && docker compose down`. Then run `base.yml --limit <host> --tags container-mgmt` from a checkout of the commit before this PR, which brings back the v1 agent; its `KOMODO_PASSKEY` is still in that host's container-mgmt `.env`. If Core was also rolled back (step 2), v1 is then fully restored.*

**5. Resource sync, once by hand.** UI -> Syncs -> New, named `homelab`, with the values from `komodo/bootstrap.toml` (repo `nathan815/homelab`, branch `main`, resource path `komodo/komodo.toml`, delete off, include variables off). Refresh, then check **Pending** before Execute. Expect updates to the two existing servers and creates for 7 stacks and the `Backup Core Database` procedure. There should be no deletes. Execute. Check: the `files_on_host` stacks (`adguardhome`, `media-system`, `nginx-proxy`, both `container-mgmt_*`) show their running containers. That proves Periphery reads `/opt/stacks/<name>`. Don't deploy anything yet.
*Rollback: delete the sync and the resources it created in the UI (the sync doesn't deploy anything, so containers are untouched). Or fix `komodo.toml` on a branch and Refresh again.*

**6. Variables, secrets and the CI key, by hand.**
- Settings -> Variables: `LANINDEX_IMAGE_TAG` = the sha after the `:` in `ssh pi01.lan "docker ps --filter label=com.docker.compose.project=lanindex --format '{{.Image}}'"`; `GRAFANA_ADMIN_PASSWORD` and `HOME_ASSISTANT_TOKEN` as secret variables.
- Re-create anything from the step 0 notes worth keeping (alerters, users, provider accounts).
- Settings -> API keys on the admin user: create a key, then update the Woodpecker repo secrets `komodo_api_key` / `komodo_api_secret` (event `deployment` only).
*Rollback: delete them. Nothing has been deployed yet.*

**7. First v2 deploys (git-backed stacks).** These move the run folder from v1's `/opt/stacks/<name>` clone to `/opt/komodo/stacks/<name>`. The compose project name stays the same, so containers are recreated in place.
- `lanindex`: run Actions -> Deploy -> Run workflow (stack `lanindex`, ref `main`). This exercises the whole CI path (GitHub -> Woodpecker -> `ci/komodo-deploy.sh` -> v2 API). Check the Woodpecker log shows a successful update and `curl -fsS http://pi01.lan:8500` answers.
- `monitoring`: same, stack `monitoring`. Check Grafana and Uptime Kuma come back with their data (`/mnt/data1/monitoring-data`, untouched).
*Rollback: `cd /opt/stacks/<name> && docker compose up -d`. The v1 clone is still there and has the `.env` v1 wrote. Then investigate.*

**8. Clean up (after about a week stable).** Remove the stale v1 clones (`/opt/stacks/lanindex`, `/opt/stacks/monitoring`, or their `.ansible-bak` copies). Run `ls -la` first: they should hold only git files and `.env`. Remove `/opt/stacks/komodo/komodo.env`. Remove the v1 volumes `docker volume rm komodo_sqlite-data komodo_repo-cache` on pi01 (plus `komodo_mongo-config` and `komodo_mongo-data`, unused since Dec 2024), and `container-mgmt_komodo-ssl-certs` on every host. Keep `/opt/appdata/komodo/v1-backup` for a while longer, then delete it.
*Rollback: none needed. After this step v1 can only be restored from the step 1 tarball (`tar xzf` into a fresh `komodo_sqlite-data` volume).*

Afterwards: Dockge can be retired (#6 note) once nothing needs its UI. Remove it from `stacks/container-mgmt`.

## One-time setup notes

1. **Git access**: none needed, the repo is public. If it ever goes private, add a GitHub account under Settings -> Providers and set `git_account` on the stacks and sync.
2. **The `homelab` sync** is deliberately not in `komodo.toml`, because a sync can't update its own resource while running ("resource busy"). Its config is recorded in `komodo/bootstrap.toml` (not read by the sync) so a fresh Komodo can recreate it. To test from a branch, set the sync's branch in the UI, and set it back to `main` after merging. **Check the Pending tab before Execute.**
3. **API key for CI**: Settings -> API keys -> create one (the dialog shows a key `K-...` and a secret `S-...`; the secret is shown only once), **on an admin user** (CI sets Komodo variables, and `UpdateVariableValue` is admin only). Add it to Woodpecker as repo secrets `komodo_api_key` and `komodo_api_secret`, limited to the `deployment` event. Keep the repo non-Trusted in Woodpecker. Leave the `homelab` sync's "include variables" off: CI owns the `<STACK>_IMAGE_TAG` variables.
4. **Woodpecker** (push events only): in the repo's settings turn OFF "Allow pull requests" (public repo, self-hosted agent). GitHub reaches Woodpecker's `/api/hook` for the `deployment` event via `https://ci-hooks.nathancj.com` (cloudflared tunnel -> `nginx-public`, which forwards only POST `/api/hook`).
5. **ghcr.io packages**: after the first deploy of a stack with an `apps/<name>/` image, set the `<name>` package visibility to public so the host can pull without credentials.
6. **Database backups**: the `Backup Core Database` procedure (in `komodo.toml`) dumps the DB daily to `/opt/appdata/komodo/backups` on pi01 and keeps 14. Restore uses `km database restore` from the `ghcr.io/moghtech/komodo-cli` image (https://komo.do/docs/setup/backup).
7. Optional: add a GitHub webhook to `/listener/github/sync/homelab/sync` so toml edits apply on push.
8. **New host**: add it to `komodo-servers` in `ansible/inventory.yml` with `komodo_server_name`, add a `[[server]]` block, and run `base.yml --limit <host> --tags komodo-periphery -e komodo_onboarding_key=...`.

## Migrating a stack (Ansible -> Komodo git mode)
Komodo clones git-backed stacks into `/opt/komodo/stacks/<stack>`, separate from Ansible's `/opt/stacks/<stack>`, so the two copies no longer collide. A relative `./data` mount would still follow the stack into the clone, though, and start empty there. Runtime data now lives in `/opt/appdata/<stack>` (#9); only `adguardhome` and octoprint's `dockge` still have to be moved. `lanindex` has no volumes and is safe. Per stack:
0. Check the stack's compose file for relative `./data` mounts. If it has any, change them to `${APPDATA_DIR:-/opt/appdata}/<stack>/...` and move the data on the host first, following `docs/appdata-migration.md` (#9): `stacks/migrate-appdata.sh <stack>` on the host copies `./data/` to `/opt/appdata/<stack>/`, verifies it and keeps `./data.pre-appdata` as the rollback copy. Then deploy with Ansible `--tags <stack>` and verify. Do the data move and that deploy together. Ansible's `deploy-stack` refuses to deploy a stack that mounts `APPDATA_DIR` while `/opt/stacks/<stack>/data` still exists, because it would start on empty data.
1. Replace its `files_on_host` block with a git-backed `[[stack]]` block (`repo`, `run_directory = "stacks/<name>"`), and remove the stack from `ansible/playbooks/*.yml`, in one PR. Sync after merge.
2. Deploy from Komodo. Same project name, so the containers are recreated from `/opt/komodo/stacks/<name>`. Confirm.
3. Delete the old `/opt/stacks/<stack>` once nothing reads it (check `ls -la` for anything that isn't from git).

### monitoring (one-off, #7)
Written for v1, where Komodo cloned into `/opt/stacks/monitoring`. Under v2 the clone lives in `/opt/komodo/stacks/monitoring`, so the script moving `/opt/stacks/monitoring` aside is harmless either way.
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

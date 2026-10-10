# Komodo GitOps

`komodo.toml` declares the servers and stacks Komodo manages. Compose files stay in `stacks/<name>/`.

## One-time setup (Komodo UI, http://komodo.lan.nathancj.com)

1. **Git access**: none needed, the repo is public. If it ever goes private, add a GitHub account under Settings -> Providers and set `git_account` on the stacks and sync.
2. **Periphery** runs on each host as `komodo-periphery` in the `container-mgmt` stack (deployed by `ansible/playbooks/base.yml`, image pinned to `ghcr.io/mbecker20/periphery:1.16`, port 8120, auth via `KOMODO_PASSKEY`). Confirm the `pi01` server shows as connected in Komodo before syncing. Note Periphery's `PERIPHERY_STACK_DIR` is `/opt/stacks`, the same directory Ansible's `deploy-stack` role and Dockge use: check where Komodo writes a git-backed stack before migrating one, so the two don't fight over `/opt/stacks/<name>`.
3. **The `homelab` sync already exists** in Komodo (repo `nathan815/homelab`, path `komodo/komodo.toml`) and is deliberately not in `komodo.toml`, because a sync can't update its own resource while running ("resource busy"). Its config is recorded in `komodo/bootstrap.toml` (not read by the sync) so a fresh Komodo can recreate it. To test from a branch, set the sync's branch in the UI; set it back to `main` after merging. `komodo.toml` was seeded from the live config, so Refresh should show only new/changed resources. **Check the Pending tab before Execute**, especially for deletions.
4. **API key for CI**: Settings -> API keys -> create one, **on an admin user** (CI sets Komodo variables, and `UpdateVariableValue` is admin only). Add it to Woodpecker as repo secrets `komodo_api_key` and `komodo_api_secret`, limited to the `deployment` event. Keep the repo non-Trusted in Woodpecker.
   Leave the `homelab` sync's "include variables" off: CI owns the `<STACK>_IMAGE_TAG` variables.
5. **Woodpecker** (push events only): in the repo's settings turn OFF "Allow pull requests" (public repo, self-hosted agent). GitHub must be able to reach Woodpecker's `/api/hook` for the `deployment` event, so a public route to just that path is required (not set up yet).
6. **ghcr.io packages**: after the first deploy of a stack with an `apps/<name>/` image, set the `<name>` package visibility to public so the host can pull without credentials.
7. Optional: add a GitHub webhook to `/listener/github/sync/homelab/sync` so toml edits apply on push.

## Migrating a stack
Komodo clones git-backed stacks into `/opt/stacks/<stack>` on the host, the same directory Ansible's `deploy-stack` role copies to. Neither tool can use the folder while the other's copy is there (a plain-files folder makes Komodo fail with "not a git repository" / "Failed to write / clone compose file"). **Stacks with runtime data in the stack folder (relative `./data/...` mounts: `media-system`, `adguardhome`, `container-mgmt`, `dashkiosk`, `upsnap`, `viewtube`) must NOT be migrated this way yet.** Moving the folder aside takes the data with it, and the service would start empty; in git mode the folder is also Komodo's to re-clone. Move the data to a host path outside `/opt/stacks` first (tracked in #9). `lanindex` has no volumes and is safe. Per stack:
0. Check the stack's compose file for relative `./data` mounts; if any, do #9 for it first.
1. Add a `[[stack]]` block (git mode) and sync.
2. Remove the stack from `ansible/playbooks/*.yml` so Ansible stops writing to it.
3. On the host, move the Ansible-copied folder aside: `sudo mv /opt/stacks/<stack> /opt/stacks/<stack>.ansible-bak` (the running containers are unaffected).
4. Redeploy from Komodo, confirm, then delete the `.ansible-bak` folder.

## Deploy flow
push to main -> `.github/workflows/deploy.yml`:
1. runs `validate.yml` (`needs`), so a failing check blocks every build and deploy;
2. finds the stacks whose `stacks/<name>/` or `apps/<name>/` changed, keeping only git-backed stacks in `komodo.toml` (`.github/scripts/deploy_plan.py`);
3. one matrix job per stack (concurrency group per stack): if `apps/<name>/Dockerfile` exists, builds arm64 on `ubuntu-24.04-arm` and pushes `ghcr.io/nathan815/<name>:<sha>` (and `:latest`); then creates a GitHub deployment with task `deploy:<name>`.

Woodpecker (`.woodpecker/deploy.yaml`, deployment events whose task starts with `deploy:`) runs `ci/komodo-deploy.sh`: for stacks with an image it sets the Komodo variable `<NAME>_IMAGE_TAG` (uppercase, `-` -> `_`) to the sha, then calls `DeployStack` and polls the update, failing unless it succeeded.

Images are pinned to the commit sha: the stack's `environment` in `komodo.toml` has `IMAGE_TAG = [[<NAME>_IMAGE_TAG]]` and the compose file uses `image: ...:${IMAGE_TAG:-latest}`. Komodo needs the variable to exist before the stack can deploy: CI creates it on the first deploy, or create it once by hand (Settings -> Variables, value `latest`).

**Manual deploy / rollback**: Actions -> Deploy -> Run workflow with a stack and a ref (branch, tag or sha). It builds the image for that sha if it isn't already in ghcr.io, then deploys it. Rolling back = dispatching an older sha. Komodo always reads compose files from `main`, so a branch dispatch changes the image, not the compose file.

PRs run `.github/workflows/validate.yml` only (GitHub-hosted, no secrets).

## Adding a stack
1. `stacks/<name>/docker-compose.yml`, plus `apps/<name>/Dockerfile` if it's built here (image `ghcr.io/nathan815/<name>:${IMAGE_TAG:-latest}`). Third-party images need no `apps/` folder.
2. A git-backed `[[stack]]` block in `komodo.toml` named `<name>` with `run_directory = "stacks/<name>"` (copy `lanindex`). For a built image add `IMAGE_TAG = [[<NAME>_IMAGE_TAG]]` to its `environment`.
3. Sync, then push. If the stack existed under Ansible, follow "Migrating a stack" first.

# Komodo GitOps

`komodo.toml` declares the servers and stacks Komodo manages. Compose files stay in `stacks/<name>/`.

## One-time setup (Komodo UI, http://komodo.lan.nathancj.com)

1. **Git access**: none needed, the repo is public. If it ever goes private, add a GitHub account under Settings -> Providers and set `git_account` on the stacks and sync.
2. **Periphery** runs on each host as `komodo-periphery` in the `container-mgmt` stack (deployed by `ansible/playbooks/base.yml`, image pinned to `ghcr.io/mbecker20/periphery:1.16`, port 8120, auth via `KOMODO_PASSKEY`). Confirm the `pi01` server shows as connected in Komodo before syncing. Note Periphery's `PERIPHERY_STACK_DIR` is `/opt/stacks`, the same directory Ansible's `deploy-stack` role and Dockge use: check where Komodo writes a git-backed stack before migrating one, so the two don't fight over `/opt/stacks/<name>`.
3. **The `homelab` sync already exists** in Komodo (repo `nathan815/homelab`, path `komodo/komodo.toml`) and is defined in the UI only: it is deliberately not in `komodo.toml`, because a sync can't update its own resource while running ("resource busy"). To test from a branch, set the sync's branch in the UI; set it back to `main` after merging. `komodo.toml` was seeded from the live config, so Refresh should show only new/changed resources. **Check the Pending tab before Execute**, especially for deletions.
4. **API key for CI**: Settings -> API keys -> create one. Add it to Woodpecker as repo secrets `komodo_api_key` and `komodo_api_secret`.
5. **Woodpecker** (push events only): in the repo's settings turn OFF "Allow pull requests" (public repo, self-hosted agent). GitHub must be able to reach Woodpecker's `/api/hook` for the `deployment` event, so a public route to just that path is required (not set up yet).
6. **ghcr.io package**: after the first `lanindex` workflow run, set the package visibility to public so pi01 can pull without credentials.
7. Optional: add a GitHub webhook to `/listener/github/sync/homelab/sync` so toml edits apply on push.

## Migrating a stack
Add a `[[stack]]` block, sync, deploy in Komodo, confirm, then remove the stack from `ansible/playbooks/*.yml` (and `docker compose down` the old copy under `/opt/stacks` if Komodo uses another path).

## Flow (lanindex)
push to main -> GitHub Actions builds arm64 image, pushes `ghcr.io/nathan815/lanindex` -> creates a GitHub deployment -> Woodpecker (`.woodpecker/deploy-lanindex.yaml`, deployment event) -> Komodo `DeployStack` (the step polls the update until it completes and fails if it didn't succeed) -> pi01 pulls and restarts.
The `lanindex` workflow runs `validate.yml` first (`needs: validate`), so a failing check blocks the image push and the deployment.
PRs run `.github/workflows/validate.yml` only (GitHub-hosted, no secrets).

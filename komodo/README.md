# Komodo GitOps

`komodo.toml` declares the servers and stacks Komodo manages. Compose files stay in `stacks/<name>/`.

## One-time setup (Komodo UI, http://komodo.lan.nathancj.com)

1. **Git access**: none needed, the repo is public. If it ever goes private, add a GitHub account under Settings -> Providers and set `git_account` on the stacks and sync.
2. **Periphery**: each server in `komodo.toml` needs a Periphery agent answering at its `address` (pi01: `https://pi01.lan:8120`). Periphery is installed outside this repo (not defined in `stacks/komodo/`), so confirm each server shows as connected in Komodo before syncing.
3. **Create the sync**: Syncs -> New -> name `homelab`, repo `nathan815/homelab`, branch `main`, resource path `komodo/komodo.toml`. Review the diff, then Execute.
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

# Komodo GitOps

`komodo.toml` declares the servers and stacks Komodo manages. Compose files stay in `stacks/<name>/`.

## One-time setup (Komodo UI, http://komodo.lan.nathancj.com)

1. **Git access**: none needed, the repo is public. If it ever goes private, add a GitHub account under Settings -> Providers and set `git_account` on the stacks and sync.
2. **Periphery on pi01**: the `pi01` server only works if a Komodo Periphery agent answers at `https://pi01.lan:8120`. The compose in `stacks/komodo/` does not run one; install it (see Komodo docs) before syncing.
3. **Create the sync**: Syncs -> New -> name `homelab`, repo `nathan815/homelab`, branch `main`, resource path `komodo/komodo.toml`. Review the diff, then Execute.
4. **API key for CI**: Settings -> API keys -> create one. Add it to Woodpecker as repo secrets `komodo_api_key` and `komodo_api_secret`.
5. Optional: add a GitHub webhook to `/listener/github/sync/homelab/sync` so toml edits apply on push.

## Migrating a stack
Add a `[[stack]]` block, sync, deploy in Komodo, confirm, then remove the stack from `ansible/playbooks/*.yml` (and `docker compose down` the old copy under `/opt/stacks` if Komodo uses another path).

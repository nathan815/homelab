# Authentik (SSO) and the MCP gateway

Stack: `stacks/authentik` on docker-main (Postgres + server + worker; no Redis in 2026.x).

## First deploy
1. `sh komodo/scripts/authentik-secrets.sh`, add both values as secret Komodo variables.
2. Deploy the `authentik` stack, then open `http://docker-main.lan:9000/if/flow/initial-setup/`
   to set the `akadmin` password.
3. For claude.ai, add a public hostname in the Cloudflare Zero Trust tunnel dashboard
   (e.g. `auth.nathancj.com` -> `http://docker-main.lan:9000`). Only the OAuth endpoints
   need to be reachable by claude.ai, but the login page is public too: enable MFA on admin.

## Services that can use Authentik OIDC natively
Grafana, Komodo, Woodpecker, Home Assistant (via a custom integration), Portainer-style UIs.
## Services that need forward-auth (nginx `auth_request` or an Authentik outpost)
Anything with its own password and no OIDC: Sonarr, Radarr, Prowlarr, Bazarr, qBittorrent,
Prometheus, Uptime Kuma, AdGuard Home, UpSnap, Dockge, Loki, lanindex.

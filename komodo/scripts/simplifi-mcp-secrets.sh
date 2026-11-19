#!/bin/sh
# Generate the Komodo variables for the simplifi-mcp stack and print them to
# stdout only (nothing is written to disk). Paste them into Komodo
# (Settings -> Variables), marking each as secret.
#
#   komodo/scripts/simplifi-mcp-secrets.sh <public-hostname> [quicken-email]
#
# <public-hostname> is the Cloudflare Tunnel public hostname (e.g. simplifi.example.com).
# In Zero Trust -> Networks -> Tunnels -> (homelab tunnel) -> Public hostnames, add it
# with service http://docker-main.lan:8787.
# ALLOWED_EMAIL limits sign-in to your Quicken account.
set -eu

hostname=${1:?usage: $0 <public-hostname> [quicken-email]}
email=${2:-}
jwt=$(openssl rand -hex 32)

cat <<OUT
SIMPLIFI_MCP_PUBLIC_BASE_URL=https://$hostname
SIMPLIFI_MCP_OAUTH_JWT_SECRET=$jwt
SIMPLIFI_MCP_ALLOWED_EMAIL=${email:-<your Quicken email>}
OUT

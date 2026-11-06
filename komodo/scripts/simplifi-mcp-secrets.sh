#!/bin/sh
# Generate the Komodo variables for the simplifi-mcp stack and print them to
# stdout only (nothing is written to disk). Paste them into Komodo
# (Settings -> Variables), marking each as secret.
#
#   komodo/scripts/simplifi-mcp-secrets.sh <tailnet>.ts.net [quicken-email]
#
# Variables: TS_HOSTNAME is a neutral, random Funnel node name; PUBLIC_BASE_URL is
# the Funnel URL; ALLOWED_EMAIL limits sign-in to your Quicken account; the
# tailnet needs tag:funnel with the `funnel` nodeAttr (see the PR for stacks/simplifi-mcp).
#
# SIMPLIFI_MCP_TS_AUTHKEY can't be generated here: create it in the Tailscale
# admin console (Settings -> Keys, reusable off, tagged) and add it by hand.
set -eu

tailnet=${1:?usage: $0 <tailnet>.ts.net [quicken-email]}
email=${2:-}
host=$(openssl rand -hex 6)
jwt=$(openssl rand -hex 32)

cat <<OUT
SIMPLIFI_MCP_TS_HOSTNAME=$host
SIMPLIFI_MCP_PUBLIC_BASE_URL=https://$host.$tailnet
SIMPLIFI_MCP_OAUTH_JWT_SECRET=$jwt
SIMPLIFI_MCP_ALLOWED_EMAIL=${email:-<your Quicken email>}
SIMPLIFI_MCP_TS_AUTHKEY=<create in the Tailscale admin console>
OUT

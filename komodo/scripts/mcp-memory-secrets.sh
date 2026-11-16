#!/bin/sh
# Generate the Komodo variables for the mcp-memory stack and print them to
# stdout only (nothing is written to disk). Pipe them straight into Komodo:
#
#   TS_AUTHKEY=tskey-... komodo/scripts/mcp-memory-secrets.sh <tailnet>.ts.net [hostname] \
#     | komodo/scripts/komodo-set-vars.sh
#
# MCP_MEMORY_TS_HOSTNAME defaults to a neutral random name, since the Funnel
# URL is public. MCP_MEMORY_API_KEY is what clients send (X-API-Key header) and
# what the OAuth consent page asks for. MCP_MEMORY_OAUTH_SECRET_KEY signs OAuth
# tokens.
#
# The Tailscale auth key can't be generated here: create it in the Tailscale
# admin console (Settings -> Keys, reusable off, tagged with the tag that has
# the `funnel` nodeAttr, like simplifi-mcp's) and pass it as TS_AUTHKEY, or
# leave it out and set MCP_MEMORY_TS_AUTHKEY in Komodo by hand.
set -eu

tailnet=${1:?usage: $0 <tailnet>.ts.net [hostname]}
host=${2:-$(openssl rand -hex 6)}

cat <<OUT
MCP_MEMORY_TS_HOSTNAME=$host
MCP_MEMORY_PUBLIC_BASE_URL=https://$host.$tailnet
MCP_MEMORY_API_KEY=$(openssl rand -hex 32)
MCP_MEMORY_OAUTH_SECRET_KEY=$(openssl rand -hex 32)
MCP_MEMORY_TS_AUTHKEY=${TS_AUTHKEY:-<create in the Tailscale admin console>}
OUT

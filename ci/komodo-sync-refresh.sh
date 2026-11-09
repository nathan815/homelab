#!/bin/sh
# Refresh the Komodo resource sync "homelab" (re-read komodo/komodo.toml from
# git and compute the Pending diff). Does not execute the sync. Run by
# .woodpecker/sync-refresh.yaml.
#
# Env: KOMODO_URL, KOMODO_API_KEY, KOMODO_API_SECRET.
# API: POST /write {"type":"RefreshResourceSyncPending","params":{"sync":...}}
# (checked against komodo_client v2.3.4 naming; returns the ResourceSync).
set -eu

SYNC=${KOMODO_SYNC:-homelab}
resp=$(mktemp)
trap 'rm -f "$resp"' EXIT

body=$(jq -nc --arg sync "$SYNC" '{type: "RefreshResourceSyncPending", params: {sync: $sync}}')
code=$(curl -sS -o "$resp" -w '%{http_code}' -X POST "$KOMODO_URL/write" \
  -H "Content-Type: application/json" \
  -H "X-Api-Key: $KOMODO_API_KEY" \
  -H "X-Api-Secret: $KOMODO_API_SECRET" \
  -d "$body") || { echo "No response from $KOMODO_URL" >&2; exit 1; }
case $code in
  2??) echo "Refreshed Komodo sync '$SYNC'; check its Pending tab and Execute if the diff looks right." ;;
  *)
    echo "RefreshResourceSyncPending failed: HTTP $code" >&2
    jq -r '.error, (.trace[]? | "  " + .)' "$resp" >&2 2> /dev/null || cat "$resp" >&2
    exit 1
    ;;
esac

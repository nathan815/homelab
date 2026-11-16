#!/bin/sh
# Save NAME=value lines from stdin as secret Komodo variables, e.g.
#
#   komodo/scripts/mcp-memory-secrets.sh <tailnet>.ts.net | komodo/scripts/komodo-set-vars.sh
#
# Existing variables are left alone, so re-running never rotates a key that
# clients already use; pass --force to overwrite them. Values that are still
# placeholders (<...>) and blank or # lines are skipped. Values are sent to
# curl on stdin, never on its command line, and are never printed.
#
# Env: KOMODO_API_KEY, KOMODO_API_SECRET (an admin user's key: creating and
# updating variables is admin only), KOMODO_URL (default http://pi01.lan:9120).
# API shapes: see ci/komodo-deploy.sh. CreateVariable {name, value, is_secret},
# UpdateVariableValue {name, value}, ListVariables -> [{name, ...}].
set -eu

force=false
case ${1:-} in
  --force) force=true ;;
  "") ;;
  *) echo "usage: <NAME=value lines> | $0 [--force]" >&2; exit 2 ;;
esac

: "${KOMODO_API_KEY:?set KOMODO_API_KEY}"
: "${KOMODO_API_SECRET:?set KOMODO_API_SECRET}"
KOMODO_URL=${KOMODO_URL:-http://pi01.lan:9120}

resp=$(mktemp)
trap 'rm -f "$resp"' EXIT

# call <read|write> <json>: print the response body, or fail with Komodo's error.
# The body goes to curl on stdin so secret values don't show up in `ps`.
call() {
  type=$1 body=$2
  code=$(printf '%s' "$body" | curl -sS -o "$resp" -w '%{http_code}' -X POST "$KOMODO_URL/$type" \
    -H "Content-Type: application/json" \
    -H "X-Api-Key: $KOMODO_API_KEY" \
    -H "X-Api-Secret: $KOMODO_API_SECRET" \
    --data-binary @-) || { echo "Komodo $type request failed (no response from $KOMODO_URL)" >&2; exit 1; }
  case $code in
    2??) cat "$resp" ;;
    *)
      echo "Komodo $type $(printf '%s' "$body" | jq -r .type) failed: HTTP $code" >&2
      jq -r '.error, (.trace[]? | "  " + .)' "$resp" >&2 2> /dev/null || cat "$resp" >&2
      exit 1
      ;;
  esac
}

# Two steps, not one pipeline: call's exit must fail the assignment (set -e).
vars_json=$(call read '{"type":"ListVariables","params":{}}')
existing=$(printf '%s' "$vars_json" | jq -r '.[].name')

while IFS= read -r line || [ -n "$line" ]; do
  case $line in "" | \#*) continue ;; esac
  name=${line%%=*}
  value=${line#*=}
  case $name in
    "$line" | "" | *[!A-Za-z0-9_]*) echo "Skipping malformed line (want NAME=value)" >&2; continue ;;
  esac
  case $value in
    "" | "<"*">") echo "skip     $name (no value yet; set it in Komodo)"; continue ;;
  esac

  if printf '%s\n' "$existing" | grep -qx "$name"; then
    if [ "$force" = true ]; then
      call write "$(jq -nc --arg n "$name" --arg v "$value" \
        '{type: "UpdateVariableValue", params: {name: $n, value: $v}}')" > /dev/null
      echo "updated  $name"
    else
      echo "exists   $name (left as is; --force to overwrite)"
    fi
  else
    call write "$(jq -nc --arg n "$name" --arg v "$value" \
      '{type: "CreateVariable", params: {name: $n, value: $v, is_secret: true}}')" > /dev/null
    echo "created  $name"
  fi
done

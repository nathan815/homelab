#!/bin/sh
# Deploy one Komodo stack. Run by .woodpecker/deploy.yaml for a GitHub
# deployment whose task is deploy:<stack>, from a checkout of the deployed sha.
#
# If apps/<stack>/Dockerfile exists, the image ghcr.io/<owner>/<stack>:<sha> was
# built by .github/workflows/deploy.yml; pin the stack to it by setting the
# Komodo variable <STACK>_IMAGE_TAG (interpolated into the stack's IMAGE_TAG
# env in komodo/komodo.toml) before deploying.
#
# Env: KOMODO_URL, KOMODO_API_KEY, KOMODO_API_SECRET, plus Woodpecker's
# CI_PIPELINE_DEPLOY_TASK and CI_COMMIT_SHA.
#
# API shapes checked against Komodo v2.3.4 (komodo_client request.rs and
# api/{read,write,execute}): POST /<read|write|execute> with
# {"type": ..., "params": ...} and X-Api-Key/X-Api-Secret headers;
# DeployStack {stack} returns an Update ({"_id": {"$oid"}, status, success,
# logs[].stage/stdout/stderr}); GetUpdate {id}; ListVariables -> [{name, ...}];
# CreateVariable / UpdateVariableValue {name, value}.
set -eu

stack=${CI_PIPELINE_DEPLOY_TASK#deploy:}
case $stack in
  "" | *[!a-z0-9-]*)
    echo "Invalid deploy task '$CI_PIPELINE_DEPLOY_TASK' (want deploy:<stack>)" >&2
    exit 1
    ;;
esac

resp=$(mktemp)
trap 'rm -f "$resp"' EXIT

# call <read|write|execute> <json>: print the response body, or fail with the
# request type, HTTP status and Komodo's {"error", "trace"} message.
call() {
  code=$(curl -sS -o "$resp" -w '%{http_code}' -X POST "$KOMODO_URL/$1" \
    -H "Content-Type: application/json" \
    -H "X-Api-Key: $KOMODO_API_KEY" \
    -H "X-Api-Secret: $KOMODO_API_SECRET" \
    -d "$2") || { echo "Komodo $1 request failed (no response from $KOMODO_URL)" >&2; exit 1; }
  case $code in
    2??) cat "$resp" ;;
    *)
      echo "Komodo $1 $(echo "$2" | jq -r .type) failed: HTTP $code" >&2
      jq -r '.error, (.trace[]? | "  " + .)' "$resp" >&2 2> /dev/null || cat "$resp" >&2
      exit 1
      ;;
  esac
}

if [ -f "apps/$stack/Dockerfile" ]; then
  var=$(echo "${stack}_IMAGE_TAG" | tr 'a-z-' 'A-Z_')
  body=$(jq -nc --arg name "$var" --arg value "$CI_COMMIT_SHA" '{name: $name, value: $value}')
  # Creating and updating variables is admin only, so the API key must belong
  # to an admin user (a non-admin gets HTTP 403 "Only Admins can ...").
  vars=$(call read '{"type":"ListVariables","params":{}}')
  if echo "$vars" | jq -e --arg name "$var" 'any(.[]; .name == $name)' > /dev/null; then
    call write "{\"type\":\"UpdateVariableValue\",\"params\":$body}" > /dev/null
  else
    call write "{\"type\":\"CreateVariable\",\"params\":$body}" > /dev/null
  fi
  echo "Set Komodo variable $var=$CI_COMMIT_SHA"
fi

# Komodo's execute call returns as soon as the update is created, so poll the
# update until it completes and fail unless it succeeded.
update=$(call execute "{\"type\":\"DeployStack\",\"params\":{\"stack\":\"$stack\"}}")
id=$(echo "$update" | jq -er '._id["$oid"]')
echo "Komodo update $id started (DeployStack $stack)"
i=0
while [ $i -lt 120 ]; do
  u=$(call read "{\"type\":\"GetUpdate\",\"params\":{\"id\":\"$id\"}}")
  if [ "$(echo "$u" | jq -r .status)" = "Complete" ]; then
    echo "$u" | jq -r '.logs[]? | "[\(.stage)] \(.stdout) \(.stderr)"'
    [ "$(echo "$u" | jq -r .success)" = "true" ]
    exit $?
  fi
  i=$((i + 1))
  sleep 5
done
echo "Timed out waiting for Komodo update $id" >&2
exit 1

#!/usr/bin/env bash
# Usage: ./run.sh up | scenario <file> [--approve once|deny|none] | logs | down
# All resources are prefixed plugspike- ; nothing is published to the host.
set -euo pipefail
cd "$(dirname "$0")"
IMG=${HERMES_IMAGE:-nousresearch/hermes-agent:v0.22.5@sha256:9c5561579f3ffdf333401797094ac3a743738d6c25d40f4331c7bf77b694238d}
PY=${PY_IMAGE:-python:3.12-alpine@sha256:5789aa194f757888f41fa3d48e14b6feaa1b57c0af0b56fcb1372d6474d3bff0}
NET=plugspike-net
ENDPOINT=${ENDPOINT:-unix:///sock/trusted.sock}     # or tcp://plugspike-trusted:9000
CFG=${CFG:-config/config.yaml}

up() {
  docker network inspect $NET >/dev/null 2>&1 || docker network create --internal $NET >/dev/null
  docker volume create plugspike-data >/dev/null; docker volume create plugspike-sock >/dev/null
  # seed HERMES_HOME (/opt/data) with plugin + config (user plugin dir = $HERMES_HOME/plugins)
  docker run --rm --entrypoint sh -v plugspike-data:/opt/data -v "$PWD":/src:ro "$IMG" -c \
    "mkdir -p /opt/data/plugins/outbound_bridge && cp -r /src/plugin/outbound_bridge/. /opt/data/plugins/outbound_bridge/ && cp /src/$CFG /opt/data/config.yaml && chmod -R a+rX /opt/data/plugins"
  docker rm -f plugspike-llm >/dev/null 2>&1 || true
  docker run -d --name plugspike-llm --network $NET -v "$PWD/mock_llm.py":/mock_llm.py:ro "$PY" python -u /mock_llm.py >/dev/null
}

start_hermes() {
  docker rm -f plugspike-hermes >/dev/null 2>&1 || true
  # NOTE: no -p / --publish. Internal network => no internet either.
  docker run -d --name plugspike-hermes --network $NET \
    -v plugspike-data:/opt/data -v plugspike-sock:/sock \
    -e OUTBOUND_BRIDGE_ENDPOINT="$ENDPOINT" -e OPENAI_API_KEY=test-key ${EXTRA_DOCKER_ARGS:-} \
    "$IMG" gateway run --no-supervise -vv >/dev/null
}

scenario() {
  local script=$1; shift
  local listen=${LISTEN:-unix:///sock/trusted.sock}
  docker rm -f plugspike-trusted >/dev/null 2>&1 || true
  # trusted side starts first (it listens); Hermes then dials out to it.
  docker run -d --name plugspike-trusted --network $NET -v plugspike-sock:/sock \
    -v "$PWD":/w:ro "$PY" python -u /w/trusted.py --listen "$listen" --script "/w/$script" "$@" >/dev/null
  sleep 1
  if [ "$(docker inspect -f '{{.State.Running}}' plugspike-hermes 2>/dev/null)" != true ]; then start_hermes; fi  # else: running Hermes re-dials us by itself
  # follow trusted until it exits (script finished + 2s)
  docker wait plugspike-trusted >/dev/null
  docker logs plugspike-trusted
}

down() {
  for c in plugspike-hermes plugspike-trusted plugspike-llm plugspike-extract plugspike-tar; do docker rm -f $c >/dev/null 2>&1 || true; done
  docker volume rm plugspike-data plugspike-sock >/dev/null 2>&1 || true
  docker network rm $NET >/dev/null 2>&1 || true
  docker ps -a --filter name=plugspike --format 'left over: {{.Names}}'
}

case "${1:-}" in
  up) up ;;
  # fresh container AND fresh data volume (a reused volume has the profile registered as an s6
  # service, which makes `gateway run --no-supervise` refuse to start)
  fresh) docker rm -f plugspike-hermes plugspike-trusted >/dev/null 2>&1 || true; docker volume rm plugspike-data >/dev/null 2>&1 || true; up ;;  # no Hermes start: `scenario` starts it
  reload)docker rm -f plugspike-hermes >/dev/null 2>&1 || true; docker volume rm plugspike-data >/dev/null 2>&1 || true
          up; start_hermes ;;
  scenario) shift; scenario "$@" ;;
  hermes-logs) docker logs plugspike-hermes 2>&1 ;;
  llm-logs) docker logs plugspike-llm 2>&1 ;;
  down) down ;;
  *) echo "usage: $0 up|scenario <file>|hermes-logs|llm-logs|down"; exit 1 ;;
esac

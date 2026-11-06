#!/bin/sh
# Build the isolated environment: internal network (no internet), mock LLM, hermes container.
set -e
cd "$(dirname "$0")"
IMG=nousresearch/hermes-agent:v0.22.5@sha256:9c5561579f3ffdf333401797094ac3a743738d6c25d40f4331c7bf77b694238d
docker network create --internal acpspike-net >/dev/null
docker volume create acpspike-data >/dev/null
# seed config into the data volume (fake key only)
docker run --rm --entrypoint sh -v acpspike-data:/opt/data -v "$PWD/config.yaml:/seed.yaml:ro" $IMG -c 'cp /seed.yaml /opt/data/config.yaml'
docker run -d --name acpspike-mock --network acpspike-net --entrypoint python3 \
  -v "$PWD/mock_llm.py:/mock_llm.py:ro" $IMG -u /mock_llm.py >/dev/null
# hermes sandbox: no published ports, internal network only; idle, we `docker exec -i ... hermes acp`
docker run -d --name acpspike-hermes --network acpspike-net -v acpspike-data:/opt/data $IMG sleep infinity >/dev/null
sleep 6
docker ps --filter name=acpspike- --format '{{.Names}} {{.Ports}}'

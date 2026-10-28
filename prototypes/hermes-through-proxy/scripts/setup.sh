#!/bin/sh
# Bring up the spike and install Hermes config. Browser NSS trust additionally needs libnss3-tools (see README).
cd "$(dirname "$0")/.."
mkdir -p certs
[ -f certs/mock.key ] || openssl req -x509 -newkey rsa:2048 -nodes -keyout certs/mock.key -out certs/mock.crt -days 30 -subj "/CN=llm.mock.test" -addext "subjectAltName=DNS:llm.mock.test,DNS:firecrawl.mock.test,DNS:search.mock.test" 2>/dev/null
[ -f certs/real_key ] || echo sk-real-looking-secret > certs/real_key   # fake; lives only in the proxy container
./dc.sh up -d --build && sleep 8 && curl -s localhost:8091/healthz && echo
docker cp config.yaml hermesproxy-hermes:/opt/data/config.yaml
docker exec hermesproxy-hermes chown hermes:hermes /opt/data/config.yaml
echo "run e.g.: python3 scripts/watch.py deny 120 llm.mock.test &  docker exec hermesproxy-hermes hermes chat -q 'say hello'"

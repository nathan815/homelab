#!/bin/sh
cd "$(dirname "$0")"
export HP="$PWD"
exec docker compose -p hermesproxy -f ../egress-proxy/docker-compose.yml -f docker-compose.override.yml "$@"

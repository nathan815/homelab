#!/bin/bash
# loki -verify-config on loki.yml, with the Loki image pinned in docker-compose.yml.
set -euo pipefail
DIR=$(cd "$(dirname "$0")" && pwd)

IMAGE=$(sed -n -E 's/^[[:space:]]*image:[[:space:]]*(grafana\/loki:[^[:space:]]+).*/\1/p' "$DIR/docker-compose.yml" | head -n 1)
[ -n "$IMAGE" ] || { echo "no grafana/loki image found in docker-compose.yml"; exit 1; }
echo "loki image = $IMAGE"

docker run --rm -v "$DIR/loki.yml:/etc/loki/loki.yml:ro" "$IMAGE" \
    -config.file=/etc/loki/loki.yml -verify-config

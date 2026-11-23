#!/bin/bash
# alloy validate on config.alloy, with the Alloy image pinned in docker-compose.yml.
set -euo pipefail
DIR=$(cd "$(dirname "$0")" && pwd)

IMAGE=$(sed -n -E 's/^[[:space:]]*image:[[:space:]]*(grafana\/alloy:[^[:space:]]+).*/\1/p' "$DIR/docker-compose.yml" | head -n 1)
[ -n "$IMAGE" ] || { echo "no grafana/alloy image found in docker-compose.yml"; exit 1; }
echo "alloy image = $IMAGE"

# The config reads these via sys.env(); values only need to be present
docker run --rm -e ALLOY_HOST=ci -e LOKI_URL=http://loki.invalid:3100/loki/api/v1/push \
    -v "$DIR/config.alloy:/etc/alloy/config.alloy:ro" "$IMAGE" validate /etc/alloy/config.alloy

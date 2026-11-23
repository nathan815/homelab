#!/bin/bash
# promtool config check for Prometheus and blackbox config check, each with the
# image pinned in docker-compose.yml.
set -euo pipefail
DIR=$(cd "$(dirname "$0")" && pwd)

image() {
    local img
    img=$(sed -n -E "s#^[[:space:]]*image:[[:space:]]*($1:[^[:space:]]+).*#\\1#p" "$DIR/docker-compose.yml" | head -n 1)
    [ -n "$img" ] || { echo "no $1 image found in docker-compose.yml" >&2; exit 1; }
    echo "$img"
}
PROMETHEUS=$(image 'prom\/prometheus')
BLACKBOX=$(image 'prom\/blackbox-exporter')
echo "prometheus image = $PROMETHEUS"
echo "blackbox image = $BLACKBOX"

# --syntax-only: the HA token credentials_file only exists at runtime
docker run --rm -v "$DIR:/work:ro" --entrypoint /bin/promtool \
    "$PROMETHEUS" check config --syntax-only /work/prometheus/prometheus.yml
docker run --rm -v "$DIR/blackbox/config:/config:ro" \
    "$BLACKBOX" --config.file=/config/blackbox.yml --config.check

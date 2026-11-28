#!/bin/bash
# promtool config/rules checks and rule unit tests for Prometheus, amtool for
# Alertmanager, and the blackbox config check, each with the image pinned in
# docker-compose.yml.
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
ALERTMANAGER=$(image 'prom\/alertmanager')
echo "prometheus image = $PROMETHEUS"
echo "blackbox image = $BLACKBOX"
echo "alertmanager image = $ALERTMANAGER"

# --syntax-only: the HA token credentials_file only exists at runtime
docker run --rm -v "$DIR:/work:ro" --entrypoint /bin/promtool \
    "$PROMETHEUS" check config --syntax-only /work/prometheus/prometheus.yml
docker run --rm -v "$DIR/blackbox/config:/config:ro" \
    "$BLACKBOX" --config.file=/config/blackbox.yml --config.check
docker run --rm -v "$DIR/prometheus:/work:ro" -w /work --entrypoint /bin/promtool \
    "$PROMETHEUS" check rules alerts.yml
docker run --rm -v "$DIR/prometheus:/work:ro" -w /work --entrypoint /bin/promtool \
    "$PROMETHEUS" test rules alerts_test.yml
# The *_file secrets only exist at runtime; check-config doesn't open them
docker run --rm -v "$DIR/alertmanager:/work:ro" --entrypoint /bin/amtool \
    "$ALERTMANAGER" check-config /work/alertmanager.yml

#!/bin/bash
# nginx -t for both configs, with the nginx image pinned in docker-compose.yml.
#
# nginx -t resolves every static proxy_pass host, and the LAN names only resolve
# on the LAN (not on CI runners), so each upstream host found in the configs is
# mapped to 127.0.0.1 with --add-host. Nothing here needs updating when a
# service is added.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

echo "SCRIPT_DIR = $SCRIPT_DIR"

NGINX_IMAGE=$(sed -n -E 's/^[[:space:]]*image:[[:space:]]*(nginx:[^[:space:]]+).*/\1/p' "$SCRIPT_DIR/docker-compose.yml" | head -n 1)
if [ -z "$NGINX_IMAGE" ]; then
    echo "no nginx image found in docker-compose.yml"
    exit 1
fi
echo "nginx image = $NGINX_IMAGE"

ADD_HOSTS=()
while IFS= read -r host; do
    ADD_HOSTS+=(--add-host "$host:127.0.0.1")
done < <(grep -rhoE 'proxy_pass[[:space:]]+https?://[A-Za-z0-9._-]+' "$SCRIPT_DIR/config" \
    | sed -E 's#.*://##' | grep -vE '^[0-9.]+$|^localhost$' | sort -u)
echo "upstream hosts mapped to 127.0.0.1: $(( ${#ADD_HOSTS[@]} / 2 ))"

echo "--- Validating nginx_public.conf ---"

if ! docker run --rm "${ADD_HOSTS[@]}" \
    -v "$SCRIPT_DIR/config/nginx_public.conf:/etc/nginx/conf.d/default.conf" \
    -v "$SCRIPT_DIR/config/includes:/etc/nginx/conf.d/includes" \
    "$NGINX_IMAGE" nginx -t; then
    echo "nginx_public.conf configuration is invalid"
    exit 1
fi

echo ""
echo "--- Validating nginx_internal.conf ---"

# Throwaway self-signed cert standing in for the certbot-issued one
CERT_DIR=$(mktemp -d)
trap 'rm -f "$CERT_DIR"/*.pem; rmdir "$CERT_DIR"' EXIT
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=lan.nathancj.com" \
    -keyout "$CERT_DIR/privkey.pem" -out "$CERT_DIR/fullchain.pem" 2>/dev/null
chmod 644 "$CERT_DIR"/*.pem

if ! docker run --rm "${ADD_HOSTS[@]}" \
    -v "$SCRIPT_DIR/config/nginx_internal.conf:/etc/nginx/conf.d/default.conf" \
    -v "$SCRIPT_DIR/config/includes:/etc/nginx/conf.d/includes" \
    -v "$CERT_DIR":/etc/letsencrypt/live/lan.nathancj.com:ro \
    "$NGINX_IMAGE" nginx -t; then
    echo "nginx_internal.conf configuration is invalid"
    exit 1
fi

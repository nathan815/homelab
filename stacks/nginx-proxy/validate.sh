SCRIPT_DIR=$(dirname "$0")

echo "SCRIPT_DIR = $SCRIPT_DIR"

echo "--- Validating nginx_public.conf ---"

docker run --rm \
    -v $SCRIPT_DIR/config/nginx_public.conf:/etc/nginx/conf.d/default.conf \
    -v $SCRIPT_DIR/config/includes:/etc/nginx/conf.d/includes \
    nginx nginx -t

if [ $? -ne 0 ]; then
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

docker run --rm \
    -v $SCRIPT_DIR/config/nginx_internal.conf:/etc/nginx/conf.d/default.conf \
    -v $SCRIPT_DIR/config/includes:/etc/nginx/conf.d/includes \
    -v "$CERT_DIR":/etc/letsencrypt/live/lan.nathancj.com:ro \
    nginx nginx -t

if [ $? -ne 0 ]; then
    echo "nginx_internal.conf configuration is invalid"
    exit 1
fi

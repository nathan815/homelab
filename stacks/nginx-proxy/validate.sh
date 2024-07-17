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

docker run --rm \
    -v $SCRIPT_DIR/config/nginx_internal.conf:/etc/nginx/conf.d/default.conf \
    -v $SCRIPT_DIR/config/includes:/etc/nginx/conf.d/includes \
    nginx nginx -t

if [ $? -ne 0 ]; then
    echo "nginx_internal.conf configuration is invalid"
    exit 1
fi

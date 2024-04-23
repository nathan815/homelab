SCRIPT_DIR=$(dirname "$0")

echo "--- Validating nginx_public.conf ---"

# docker run --rm -v $SCRIPT_DIR/nginx_public.conf:/etc/nginx/conf.d/default.conf nginx nginx -t
# if [ $? -ne 0 ]; then
#     echo "nginx_public.conf configuration is invalid"
#     exit 1
# fi

# echo ""
# echo "--- Validating nginx_internal.conf ---"

# docker run --rm -v $SCRIPT_DIR/nginx_internal.conf:/etc/nginx/conf.d/default.conf nginx nginx -t
# if [ $? -ne 0 ]; then
#     echo "nginx_internal.conf configuration is invalid"
#     exit 1
# fi

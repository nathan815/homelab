#!/bin/sh
# Starts nginx via the stock entrypoint, plus a background loop that reloads nginx
# when certbot renews the cert (checked hourly). Run as `sh <file>`, so no exec bit needed.
cert=/etc/letsencrypt/live/lan.nathancj.com/fullchain.pem

(
  last=$(stat -L -c %Y "$cert" 2>/dev/null)
  while sleep 3600; do
    now=$(stat -L -c %Y "$cert" 2>/dev/null)
    if [ "$now" != "$last" ]; then
      echo "$cert changed, reloading nginx"
      nginx -s reload && last=$now
    fi
  done
) &

exec /docker-entrypoint.sh nginx -g 'daemon off;'

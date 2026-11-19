#!/bin/sh
# Wait for the proxy to publish its PUBLIC CA cert, add it to the system store, then idle.
set -e
i=0
while [ ! -s /ca-public/mitmproxy-ca-cert.pem ]; do
  i=$((i+1)); [ "$i" -gt 90 ] && echo "proxy CA cert never appeared" >&2 && exit 1
  sleep 1
done
cp /ca-public/mitmproxy-ca-cert.pem /usr/local/share/ca-certificates/mitmproxy.crt
update-ca-certificates >/dev/null 2>&1
touch /tmp/ready
exec sleep infinity

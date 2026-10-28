#!/bin/sh
# Wait for the proxy's PUBLIC CA, add to the system store, then hand to the stock Hermes entrypoint.
i=0
while [ ! -s /ca-public/mitmproxy-ca-cert.pem ]; do i=$((i+1)); [ $i -gt 90 ] && echo "no CA" >&2 && exit 1; sleep 1; done
if [ "${INSTALL_SYSTEM_CA:-1}" = 1 ]; then
  cp /ca-public/mitmproxy-ca-cert.pem /usr/local/share/ca-certificates/mitmproxy.crt
  update-ca-certificates >/dev/null 2>&1
fi
exec /opt/hermes/docker/entrypoint-dispatch.sh "$@"

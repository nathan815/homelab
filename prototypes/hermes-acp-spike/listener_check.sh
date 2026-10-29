#!/bin/sh
# Compare listening sockets in the container before vs. while `hermes acp` runs (with a live prompt-capable session).
C=acpspike-hermes
snap() { docker exec $C sh -c 'for f in tcp tcp6 udp udp6; do echo "# $f"; awk "NR>1 && (\$4==\"0A\" || \"$f\" ~ /udp/) {print \$2, \$4}" /proc/net/$f; done'; }
echo "=== BEFORE"; snap
( { printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1,"clientCapabilities":{}}}'
    printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"session/new","params":{"cwd":"/tmp","mcpServers":[]}}'
    sleep 25; } | docker exec -i -u hermes $C hermes acp >/dev/null 2>&1 ) &
sleep 15
echo "=== DURING (hermes acp running; process list:)"; docker exec $C sh -c 'ps -eo pid,args | grep -i "[h]ermes"'
snap
wait

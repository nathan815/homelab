#!/bin/sh
for c in acpspike-hermes acpspike-mock acpspike-trusted; do docker stop $c 2>/dev/null; docker rm $c 2>/dev/null; done
docker network rm acpspike-net 2>/dev/null
docker volume rm acpspike-data 2>/dev/null
true

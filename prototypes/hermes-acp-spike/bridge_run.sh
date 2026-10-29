#!/bin/sh
# End-to-end: client.py -> (docker run -i) trusted_side.py [listens] <== TCP, initiated from inside ==> shim.py -> hermes acp
set -e
cd "$(dirname "$0")"
docker stop acpspike-trusted >/dev/null 2>&1 || true
docker cp shim.py acpspike-hermes:/tmp/shim.py
# launch the in-sandbox shim shortly after the trusted side starts listening (outbound connect from inside)
( sleep 4; docker exec -u hermes acpspike-hermes python3 /tmp/shim.py acpspike-trusted 9000 -- hermes acp ) &
python3 client.py --cmd "docker run -i --rm --name acpspike-trusted --network acpspike-net --entrypoint python3 -v $PWD/trusted_side.py:/t.py:ro nousresearch/hermes-agent:v0.22.5@sha256:9c5561579f3ffdf333401797094ac3a743738d6c25d40f4331c7bf77b694238d -u /t.py 9000" "$@"
wait

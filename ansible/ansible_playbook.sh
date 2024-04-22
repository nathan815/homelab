#!/bin/bash
ARGS=$@

IMAGE=ansible:latest

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
MOUNT_DIR="$(dirname "$SCRIPT_DIR")"

CMD="cd /work/ansible && ansible-playbook -e @secrets.yml $ARGS"
echo "[ansible container]  $CMD"

docker run -it -v "$MOUNT_DIR":/work -v ~/.ssh:/root/.ssh "$IMAGE" \
    sh -c "$CMD"

# Examples
# ./run_playbook.sh pi_setup.yml
# ./run_playbook.sh pi_setup.yml --tags monitoring
# ./run_playbook.sh pi_setup.yml --skip-tags base

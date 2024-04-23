#!/bin/bash
ARGS=$@

IMAGE=ansible:latest

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
MOUNT_DIR="$(dirname "$SCRIPT_DIR")"

CMD="cd $MOUNT_DIR/ansible && ansible-playbook -e @secrets.yml $ARGS"
echo "[ansible container]  $CMD"

docker run -it -v "$MOUNT_DIR":"$MOUNT_DIR" \
    -v /var/run/docker.sock:/var/run/docker.sock\
    -v ~/.ssh:/root/.ssh "$IMAGE" \
    sh -c "$CMD"

# Examples
# ./run_playbook.sh pi_setup.yml
# ./run_playbook.sh pi_setup.yml --tags monitoring
# ./run_playbook.sh pi_setup.yml --skip-tags base

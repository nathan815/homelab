#!/bin/bash

IMAGE=ansible:latest

docker run -it -v $PWD:/work -v ~/.ssh:/root/.ssh "$IMAGE" \
    ansible-playbook -e @secrets.yml "$@"

# Examples
# ./run_playbook.sh pi_setup.yml
# ./run_playbook.sh pi_setup.yml --tags monitoring
# ./run_playbook.sh pi_setup.yml --skip-tags base

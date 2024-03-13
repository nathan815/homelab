#!/bin/bash

IMAGE=ansible:latest

docker run -it -v $PWD:/work -v ~/.ssh:/root/.ssh "$IMAGE" "$@"

# Examples
# ./ansible.sh ansible-galaxy collection list

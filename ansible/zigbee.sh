#!/bin/bash

docker run -it -v $PWD:/work -v ~/.ssh:/root/.ssh ansible ansible-playbook -e ansible_user=nathan -e @secrets.yml "$@" playbooks/zigbee.yml

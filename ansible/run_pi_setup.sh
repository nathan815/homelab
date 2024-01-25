#!/bin/bash

docker run -it -v $PWD:/work -v ~/.ssh:/root/.ssh ansible ansible-playbook -e ansible_user=nathan -e @secrets.yml "$@" playbooks/pi_setup.yml

# Examples
# ./run_pi_setup.sh
# ./run_pi_setup.sh --tags monitoring
# ./run_pi_setup.sh --skip-tags base
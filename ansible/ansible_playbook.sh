#!/bin/bash
# Run an ansible playbook through uv (no docker needed). Secrets come from secrets.yml.
#
#   ./ansible_playbook.sh playbooks/base.yml --limit docker.lan --tags docker-mounts --check --diff
#
# First run installs ansible (uv) and the galaxy roles from requirements.yml into .galaxy/ (git-ignored).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

export ANSIBLE_ROLES_PATH="$PWD/.galaxy/roles:$PWD/roles"
if [ ! -d .galaxy/roles/geerlingguy.docker ]; then
  echo "[uv] installing galaxy roles into .galaxy/roles"
  uv run --quiet ansible-galaxy role install -r requirements.yml -p .galaxy/roles
fi

echo "[ansible via uv]  ansible-playbook -e @secrets.yml $*"
exec uv run --quiet ansible-playbook -e @secrets.yml "$@"

#!/usr/bin/env bash
# Fail if any image reference lacks a @sha256 digest.
# Skips refs built from variables (e.g. ${IMAGE_TAG}) and the in-repo lanindex image.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

bad=$(git ls-files 'stacks/*/*.yml' 'stacks/*/*.yaml' 'ansible/roles/*/templates/docker-compose.yml.j2' \
        '.woodpecker/*.yaml' 'ansible/Dockerfile' 'apps/*/Dockerfile' |
  xargs grep -nE '^\s*(-\s*)?image:|^FROM ' |
  grep -v '@sha256:' | grep -vF '${' || true)

latest=$(git ls-files 'stacks/*/*.yml' 'stacks/*/*.yaml' 'ansible/roles/*/templates/docker-compose.yml.j2' \
        '.woodpecker/*.yaml' 'ansible/Dockerfile' 'apps/*/Dockerfile' |
  xargs grep -nE '^\s*(-\s*)?image:.*:latest@|^FROM .*:latest@' | grep -vF '${' || true)
bad="$bad$latest"

if [ -n "$bad" ]; then
  echo "Unpinned or :latest images (use <version tag>@sha256:<digest>):"
  echo "$bad"
  exit 1
fi

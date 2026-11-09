#!/bin/sh
# Make running nginx containers use the config Komodo just pulled (#55).
#
# Run as nginx-proxy's post_deploy command (komodo/komodo.toml), in the stack
# folder. `docker compose up` doesn't touch nginx when only config/ changed, and
# the single-file mounts of nginx_*.conf keep pointing at the old inode after
# git replaces the file, so a plain reload never sees the new vhosts (SNI
# "unrecognized name" for new hosts, new log_format missing).
#
#   - mounted file differs from the repo file -> restart the container, which
#     re-resolves the bind mount (a few seconds of downtime)
#   - otherwise -> nginx -t, then reload (picks up config/includes changes)
set -eu

apply() { # <container> <repo file> <path in container>
  c=$1 file=$2 target=$3
  if ! docker inspect "$c" > /dev/null 2>&1; then
    echo "$c: not running, skipped"
    return 0
  fi
  # cksum (coreutils) rather than cmp: Periphery has no diffutils guarantee
  if [ "$(docker exec "$c" cat "$target" | cksum)" = "$(cksum < "$file")" ]; then
    docker exec "$c" nginx -t
    docker exec "$c" nginx -s reload
    echo "$c: config unchanged on disk, reloaded"
  else
    echo "$c: $target is stale, restarting"
    docker restart "$c" > /dev/null
  fi
}

apply nginx-internal config/nginx_internal.conf /etc/nginx/conf.d/default.conf
apply nginx-public config/nginx_public.conf /etc/nginx/conf.d/default.conf

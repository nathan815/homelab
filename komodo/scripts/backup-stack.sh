#!/bin/sh
# Back up or restore one compose stack's persistent data (#41).
#
#   backup-stack.sh backup [stack] [project]   run in the stack's compose folder;
#                                              stack defaults to that folder's name
#   backup-stack.sh restore <archive>          host path of a backup archive
#
# Komodo runs `backup` as the stack's pre_deploy command (komodo/komodo.toml),
# after pulling the new compose file and before `docker compose pull/up`. A
# non-zero exit blocks the deploy, by design. See komodo/README.md, "Backups".
#
# What is backed up: services labelled `homelab.backup: "true"` in the compose
# file that this deploy will recreate. For each, the named volumes and the
# read-write bind mounts under BACKUP_DATA_ROOTS of its existing container(s),
# i.e. the data as it is now. Config bind-mounted from git (/opt/komodo,
# /opt/stacks) is never included. Only those containers are stopped while the
# archive is written (SQLite/WAL safe), then started again, so downtime is the
# archive time. Labelled services the deploy leaves alone keep running and are
# not archived.
#
# A service counts as recreated when:
#   - `docker compose up -d --dry-run` says Recreate for it. Compose decides
#     from its config hash (image reference, env, ports, volumes, ...) and
#     recreates dependents of a recreated service too (`depends_on`,
#     `network_mode: service:...`), e.g. everything routed through a VPN container;
#   - it has no container yet (new service);
#   - its image is not pinned by digest (the tag may have moved, so assume it
#     changes), or a service it needs (the same dependency kinds, plus
#     `pid`/`ipc: service:`, `volumes_from`, `links`) is one of the above.
# The backup is skipped when no labelled service is recreated (a deploy that
# changes nothing, or only unlabelled services). If the dry run fails (registry
# unreachable, ...), every labelled service is assumed recreated.
#
# Needs only the docker CLI, so it runs inside the Periphery container or on
# the host. Files are touched only by a throwaway helper container (the
# Periphery image: GNU tar, gzip, coreutils, on every Komodo host), so all paths
# are host paths and Periphery needs no extra mounts.
#
# Archives: $BACKUP_ROOT/<stack>/<stack>-<UTC yyyymmddThhmmssZ>.tar.gz, holding
# MANIFEST plus each bind mount at its host path (minus the leading /) and each
# volume under volumes/<name>.
#
# Env:
#   BACKUP_ROOT          host dir for archives, must exist (default /opt/appdata-backups)
#   BACKUP_KEEP          archives kept per stack (default 5)
#   BACKUP_MIN_FREE_MB   free space that must remain after the archive (default 1024)
#   BACKUP_DATA_ROOTS    host dirs whose bind mounts count as data
#                        (default "/opt/appdata /mnt/data1")
#   BACKUP_FORCE=1       back up every labelled service, whether or not it is recreated
#   BACKUP_HELPER_IMAGE  image to run tar in (default: the komodo-periphery container's)
#   COMPOSE_FILE         as for docker compose, if the stack has several files
#
# shellcheck disable=SC2016 # the '...' scripts run in the helper's shell
set -eu

BACKUP_ROOT=${BACKUP_ROOT:-/opt/appdata-backups}
BACKUP_KEEP=${BACKUP_KEEP:-5}
BACKUP_MIN_FREE_MB=${BACKUP_MIN_FREE_MB:-1024}
BACKUP_DATA_ROOTS=${BACKUP_DATA_ROOTS:-/opt/appdata /mnt/data1}
BACKUP_FORCE=${BACKUP_FORCE:-0}

log() { echo "backup-stack: $*"; }
die() {
  echo "backup-stack: ERROR: $*" >&2
  exit 1
}

usage() {
  echo "usage: $0 backup [stack] [project] | restore <archive>" >&2
  exit 2
}

helper_image() {
  if [ -n "${BACKUP_HELPER_IMAGE:-}" ]; then
    echo "$BACKUP_HELPER_IMAGE"
  else
    docker inspect -f '{{.Image}}' komodo-periphery 2> /dev/null \
      || die "no komodo-periphery container on this host; set BACKUP_HELPER_IMAGE"
  fi
}

# helper <docker run args...> -- <sh script> [args]: run a shell script in the
# helper image. ENTRIES (one "bind <path>" / "volume <name>" per line) is passed
# in the environment.
helper() {
  docker run --rm --network none --log-driver none --entrypoint sh \
    -e ENTRIES="$entries" "$@"
}

# The project's containers (not `docker compose run` one-offs), optionally for
# one service.
project_containers() {
  docker ps -aq --filter "label=com.docker.compose.project=$project" \
    --filter label=com.docker.compose.oneoff=False \
    ${1:+--filter "label=com.docker.compose.service=$1"}
}

# Services labelled homelab.backup: "true" in $1, the output of `docker compose
# config`. Compose
# normalises labels to a map, so they appear at a fixed indent.
opted_in_services() {
  echo "$1" | awk '
    /^services:/ { s = 1; next }
    s && /^[^ ]/ { s = 0 }
    s && /^  [^ ]/ { svc = $1; sub(/:$/, "", svc) }
    s && /^      homelab\.backup: / { v = $2; gsub(/"/, "", v); if (v == "true") print svc }'
}

# Dependencies in $1 (`docker compose config` output), as "<service> <service it
# needs>" lines. Compose normalises network_mode: service:X into depends_on.
service_deps() {
  echo "$1" | awk '
    /^services:/ { s = 1; next }
    s && /^[^ ]/ { s = 0 }
    s && /^  [^ ]/ { svc = $1; sub(/:$/, "", svc); key = ""; next }
    s && /^    [^ ]/ { key = $1; sub(/:$/, "", key)
      if (key ~ /^(network_mode|pid|ipc)$/ && $2 ~ /^service:/) { d = $2; sub(/^service:/, "", d); print svc, d } next }
    s && key == "depends_on" && /^      [^ -]/ { d = $1; sub(/:$/, "", d); print svc, d }
    s && (key == "volumes_from" || key == "links") && /^      - / { d = $2; sub(/:.*/, "", d); print svc, d }'
}

# The image reference of each service in $1, as "<service> <image>" lines.
service_images() {
  echo "$1" | awk '
    /^services:/ { s = 1; next }
    s && /^[^ ]/ { s = 0 }
    s && /^  [^ ]/ { svc = $1; sub(/:$/, "", svc) }
    s && /^    image: / { print svc, $2 }'
}

# add_dependents <config> <services...>: print the services plus, transitively,
# every service that depends on one of them (one per line).
add_dependents() {
  deps=$(service_deps "$1")
  shift
  list=" $* "
  grew=1
  while [ "$grew" = 1 ]; do
    grew=0
    for svc in $(echo "$deps" | awk '{ print $1 }' | sort -u); do
      case $list in *" $svc "*) continue ;; esac
      for need in $(echo "$deps" | awk -v s="$svc" '$1 == s { print $2 }'); do
        case $list in *" $need "*) list="$list$svc " grew=1 && break ;; esac
      done
    done
  done
  for svc in $list; do echo "$svc"; done | awk '!seen[$0]++'
}

# Print the services (one per line) that `docker compose up -d` will recreate,
# given the compose config in $1.
recreated_services() {
  changed=""
  for svc in $(docker compose -p "$project" config --services); do
    ref=$(service_images "$1" | awk -v s="$svc" '$1 == s { print $2 }')
    case $ref in *@sha256:*) ;; *) changed="$changed $svc" && continue ;; esac
    [ -n "$(project_containers "$svc")" ] || changed="$changed $svc"
  done
  # Compose's own plan. It reads manifests for images not pulled yet but
  # downloads nothing, and starts nothing.
  plan=$(docker compose -p "$project" up -d --dry-run --no-build 2>&1) || return 1
  # An unrecognised output format must not read as "nothing changes".
  if [ -n "$(project_containers)" ]; then
    echo "$plan" | grep -Eq 'Container .* (Running|Recreate|Started)$' || return 1
  fi
  for name in $(echo "$plan" | awk '$NF == "Recreate" && $(NF - 2) == "Container" { print $(NF - 1) }'); do
    changed="$changed $(docker inspect -f '{{index .Config.Labels "com.docker.compose.service"}}' "$name")"
  done
  # Compose recreates the dependents of what it recreates, but not of the
  # services added above.
  # shellcheck disable=SC2086
  add_dependents "$1" $changed
}

# Print "bind <path>" / "volume <name>" for a container's data mounts.
data_mounts() {
  docker inspect -f '{{range .Mounts}}{{.Type}} {{.RW}} {{if eq .Type "volume"}}{{.Name}}{{else}}{{.Source}}{{end}}{{"\n"}}{{end}}' "$1" \
    | while read -r type rw src; do
      [ "$rw" = true ] || continue
      case $type in
        volume) echo "volume $src" ;;
        bind)
          for root in $BACKUP_DATA_ROOTS; do
            case $src in "$root" | "$root"/*) echo "bind $src" && break ;; esac
          done
          ;;
      esac
    done
}

# Set mount_args (docker run -v flags, mode $1 = ro|rw) and paths (the entries'
# paths relative to /src in the helper) from $entries.
mount_entries() {
  mount_args="" paths=""
  while read -r type src; do
    case $src in *[!A-Za-z0-9._/-]*) die "unsupported characters in path: $src" ;; esac
    case $type in
      bind) mount_args="$mount_args -v $src:/src$src:$1" paths="$paths ${src#/}" ;;
      volume) mount_args="$mount_args -v $src:/src/volumes/$src:$1" paths="$paths volumes/$src" ;;
      *) continue ;;
    esac
  done << EOF
$entries
EOF
}

# Fail unless archiving $entries (counted uncompressed) leaves BACKUP_MIN_FREE_MB
# free on BACKUP_ROOT's disk.
check_space() {
  mount_entries ro
  # shellcheck disable=SC2086
  helper $mount_args --mount "type=bind,src=$BACKUP_ROOT,dst=/root-dir" "$image" -c '
    set -eu
    cd /src
    need=$(du -sk --total $0 | tail -1 | cut -f1)
    free=$(df -Pk /root-dir | awk "NR == 2 { print \$4 }")
    echo "backup-stack: data $((need / 1024)) MB (uncompressed), free $((free / 1024)) MB on the backup disk"
    if [ $((free - need)) -lt $(($1 * 1024)) ]; then
      echo "backup-stack: ERROR: would leave less than $1 MB free. Free space, lower BACKUP_KEEP or set BACKUP_ROOT, then redeploy." >&2
      exit 1
    fi' "$paths" "$BACKUP_MIN_FREE_MB"
}

# write_archive <file name> <keep>: tar $entries to $BACKUP_ROOT/$stack/<file
# name>, then keep the newest <keep> archives (0 = prune nothing).
write_archive() {
  mount_entries ro
  # shellcheck disable=SC2086
  helper $mount_args --mount "type=bind,src=$BACKUP_ROOT,dst=/root-dir" \
    -e STACK="$stack" -e PROJECT="$project" -e KEEP="$2" "$image" -c '
    set -eu
    mkdir -p "/root-dir/$STACK"
    out="/root-dir/$STACK/$1"
    trap "rm -f \"$out.partial\"" EXIT
    cd /src
    { echo "stack $STACK"; echo "project $PROJECT"; echo "$ENTRIES"; } > MANIFEST
    tar --numeric-owner -czf "$out.partial" MANIFEST $0
    mv "$out.partial" "$out"
    trap - EXIT
    echo "backup-stack: wrote $(du -h "$out" | cut -f1) $1"
    if [ "$KEEP" -gt 0 ]; then
      ls -1 "/root-dir/$STACK" | grep -E "^$STACK-[0-9]{8}T[0-9]{6}Z(-[a-z-]+)?\.tar\.gz$" \
        | sort -r | tail -n +$((KEEP + 1)) | while read -r old; do
          rm -f "/root-dir/$STACK/$old" && echo "backup-stack: pruned $old"
        done
    fi' "$paths" "$1"
}

# Stop the running containers among $1 and remember them; start_containers (also
# run on exit) starts them again.
stopped=""
stop=""
stop_containers() {
  for c in $1; do
    [ "$(docker inspect -f '{{.State.Running}}' "$c")" = true ] && stopped="$stopped $c"
  done
  if [ -n "$stopped" ]; then
    log "stopping$(for c in $stopped; do docker inspect -f ' {{.Name}}' "$c"; done | tr -d '\n/')"
    # shellcheck disable=SC2086
    docker stop -t 60 $stopped > /dev/null
  fi
}
start_containers() {
  # A container that joins another's network can't start before that one has,
  # so retry the ones that fail until they all have.
  pass=0
  while [ -n "$stopped" ] && [ "$pass" -lt 5 ]; do
    pending=""
    for c in $stopped; do
      docker start "$c" > /dev/null 2>&1 || pending="$pending $c"
    done
    stopped=$pending pass=$((pass + 1))
  done
  if [ -n "$stopped" ]; then
    echo "backup-stack: ERROR: could not start again:$stopped" >&2
    exit 1
  fi
  [ "$pass" -gt 0 ] && log "started them again"
  return 0
}
trap start_containers EXIT

timestamp() { date -u +%Y%m%dT%H%M%SZ; }

cmd_backup() {
  config=$(docker compose -p "$project" config) || die "docker compose config failed in $PWD"
  services=$(opted_in_services "$config")
  if [ -z "$services" ]; then
    log "no service in $project has the homelab.backup label, nothing to back up"
    return
  fi
  if [ "$BACKUP_FORCE" != 1 ]; then
    recreated=$(recreated_services "$config") || {
      log "docker compose up --dry-run failed, assuming every labelled service is recreated"
      recreated=$services
    }
    log "will be recreated:$(echo " $recreated" | tr '\n' ' ')"
    # Keep the labelled services that are being recreated.
    selected=""
    for svc in $services; do
      case "
$recreated
" in *"
$svc
"*) selected="$selected $svc" ;; esac
    done
    if [ -z "$selected" ]; then
      log "no labelled service is recreated by this deploy, skipping the backup (BACKUP_FORCE=1 to force)"
      return
    fi
    services=$selected
  fi
  containers=""
  for svc in $services; do
    containers="$containers $(project_containers "$svc")"
  done
  entries=$(for c in $containers; do data_mounts "$c"; done | sort -u)
  if [ -z "$entries" ]; then
    log "no existing data for$(echo " $services" | tr '\n' ' ')(first deploy?), nothing to back up"
    return
  fi
  log "backing up $project to $BACKUP_ROOT/$stack:"
  echo "$entries" | sed 's/^/  /'
  image=$(helper_image)
  check_space
  # Also stop what runs on top of them (e.g. through their network), since
  # that breaks when they restart.
  # shellcheck disable=SC2086
  for svc in $(add_dependents "$config" $services); do
    stop="$stop $(project_containers "$svc")"
  done
  stop_containers "$stop"
  write_archive "$stack-$(timestamp).tar.gz" "$BACKUP_KEEP"
  start_containers
}

cmd_restore() {
  case $archive in
    /*.tar.gz) ;;
    *) die "give the archive's absolute host path, e.g. $BACKUP_ROOT/<stack>/<stack>-<time>.tar.gz" ;;
  esac
  image=$(helper_image)
  dir=${archive%/*} file=${archive##*/}
  entries=""
  manifest=$(helper --mount "type=bind,src=$dir,dst=/b,readonly" "$image" \
    -c 'tar -xzOf "/b/$0" MANIFEST' "$file") || die "can't read MANIFEST from $archive"
  stack=$(echo "$manifest" | awk '$1 == "stack" { print $2 }')
  project=$(echo "$manifest" | awk '$1 == "project" { print $2 }')
  entries=$(echo "$manifest" | grep -E '^(bind|volume) ')
  BACKUP_ROOT=${dir%/*}
  log "restoring $file into project $project:"
  echo "$entries" | sed 's/^/  /'

  # Keep the current data first, in case the restore was a mistake.
  check_space
  containers=$(project_containers)
  stop_containers "$containers"
  write_archive "$stack-$(timestamp)-pre-restore.tar.gz" 0

  mount_entries rw
  # shellcheck disable=SC2086
  helper $mount_args --mount "type=bind,src=$dir,dst=/b,readonly" "$image" -c '
    set -eu
    cd /src
    for p in $0; do find "$p" -mindepth 1 -delete; done
    tar --numeric-owner -xzpf "/b/$1" $0
    echo "backup-stack: restored $1"' "$paths" "$file"
  start_containers
}

[ $# -ge 1 ] || usage
case $1 in
  backup)
    # Komodo runs git-backed stacks in .../stacks/<stack>, so that folder's name
    # is the stack, and the compose project unless it is renamed.
    stack=${2:-$(basename "$PWD")} project=${3:-$stack}
    cmd_backup
    ;;
  restore)
    [ $# -eq 2 ] || usage
    archive=$2
    cmd_restore
    ;;
  *) usage ;;
esac

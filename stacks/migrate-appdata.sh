#!/bin/bash
# Move a stack's runtime data from /opt/stacks/<stack>/data to /opt/appdata/<stack> (#9).
# Run on the host, before deploying the stack's new compose file:
#
#   scp stacks/migrate-appdata.sh pi01.lan:/tmp/
#   ssh pi01.lan 'sudo bash /tmp/migrate-appdata.sh upsnap --dry-run'   # checks only
#   ssh pi01.lan 'sudo bash /tmp/migrate-appdata.sh upsnap'
#
# Copies while the stack runs, stops it, copies the rest, verifies the copy and
# renames ./data to ./data.pre-appdata (the rollback copy). It does not start the
# stack: deploy the new compose file with Ansible afterwards (printed at the end).
# Any failure after the stop leaves the old data and compose file untouched.
# Full runbook: docs/appdata-migration.md
#
# Options:
#   --dry-run     run the checks and print the plan, change nothing
#   --no-prepass  skip the copy while running (stop first, copy once)
#   --checksum    verify by file contents, not just size/mtime (slower; longer downtime)

set -euo pipefail

STACKS_DIR="${STACKS_DIR:-/opt/stacks}"
APPDATA_DIR="${APPDATA_DIR:-/opt/appdata}"
RSYNC=(rsync -aHAX --numeric-ids)

die() { echo "✗ $*" >&2; exit 1; }
step() { echo; echo "==> $*"; }

STACK=""
DRY_RUN=0
PREPASS=1
VERIFY_FLAGS=()
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        --no-prepass) PREPASS=0 ;;
        --checksum) VERIFY_FLAGS=(--checksum) ;;
        -*) die "unknown option $arg" ;;
        *) [ -z "$STACK" ] || die "one stack at a time"; STACK="$arg" ;;
    esac
done
[ -n "$STACK" ] || die "usage: sudo $0 <stack> [--dry-run] [--no-prepass] [--checksum]"

STACK_DIR="$STACKS_DIR/$STACK"
SRC="$STACK_DIR/data"
BAK="$STACK_DIR/data.pre-appdata"
DST="$APPDATA_DIR/$STACK"

# --- checks (nothing changes until they all pass) ---------------------------
step "Checks for $STACK"
[ "$(id -u)" -eq 0 ] || die "run with sudo (the data has root-owned files)"
command -v rsync >/dev/null || die "rsync not installed"
command -v docker >/dev/null || die "docker not installed"
[ -d "$STACK_DIR" ] || die "$STACK_DIR does not exist"
[ -f "$STACK_DIR/docker-compose.yml" ] || die "$STACK_DIR/docker-compose.yml not found"
[ ! -e "$BAK" ] || die "$BAK already exists: already migrated, or a previous run needs cleaning up"
[ -d "$SRC" ] && [ ! -L "$SRC" ] || die "$SRC is not a directory (nothing to migrate?)"
if [ -e "$DST" ]; then
    [ -d "$DST" ] || die "$DST exists and is not a directory"
    [ -z "$(ls -A "$DST")" ] || die "$DST is not empty: refusing to merge into existing data"
fi

need_kb=$(du -sk "$SRC" | cut -f1)
probe="$DST"
while [ ! -e "$probe" ]; do probe=$(dirname "$probe"); done
avail_kb=$(df -Pk "$probe" | awk 'NR==2 {print $4}')
echo "  data:  $SRC ($((need_kb / 1024))M)"
echo "  to:    $DST ($((avail_kb / 1024))M free on $(df -P "$probe" | awk 'NR==2 {print $1}'))"
# full copy plus 10% headroom (the old dir is kept as the rollback copy)
[ $((need_kb + need_kb / 10)) -lt "$avail_kb" ] || die "not enough free space for a full copy"

running=$(cd "$STACK_DIR" && docker compose ps --services --status running 2>/dev/null | tr '\n' ' ' || true)
echo "  running services: ${running:-none}"
echo "✓ checks passed"

if [ "$DRY_RUN" -eq 1 ]; then
    echo
    echo "Dry run: would copy (pre-pass: $([ $PREPASS -eq 1 ] && echo yes || echo no)), stop the stack,"
    echo "copy again, verify, then rename $SRC -> $BAK. Nothing changed."
    exit 0
fi

# --- copy ----------------------------------------------------------------------
STOPPED=0
on_error() {
    echo
    echo "✗ Failed. $SRC and the compose file are untouched. Empty $DST before retrying."
    if [ "$STOPPED" -eq 1 ]; then
        echo "  $STACK is stopped. Restart it as before: cd $STACK_DIR && docker compose up -d"
    fi
}
trap on_error ERR
install -d "$DST"
if [ "$PREPASS" -eq 1 ]; then
    step "Pre-pass copy while the stack is running"
    "${RSYNC[@]}" "$SRC/" "$DST/"
fi

step "Stopping $STACK"
cp -p "$STACK_DIR/docker-compose.yml" "$STACK_DIR/docker-compose.yml.pre-appdata"
STOPPED=1
(cd "$STACK_DIR" && docker compose down)

step "Final copy"
"${RSYNC[@]}" --delete "$SRC/" "$DST/"

step "Verifying"
diff_out=$("${RSYNC[@]}" -n -i --delete "${VERIFY_FLAGS[@]}" "$SRC/" "$DST/")
if [ -n "$diff_out" ]; then
    echo "$diff_out" | head -20
    false  # trips the ERR trap
fi
src_count=$(find "$SRC" | wc -l)
dst_count=$(find "$DST" | wc -l)
[ "$src_count" -eq "$dst_count" ] || { echo "entry count differs: $src_count vs $dst_count"; false; }
if [ "$STACK" = "media-system" ]; then
    # single-file bind: if missing, docker would create a directory in its place
    [ -f "$DST/filebrowser/filebrowser.db" ] || { echo "filebrowser.db missing in $DST"; false; }
fi
echo "✓ identical ($src_count entries)"

step "Keeping the old data as $BAK"
mv "$SRC" "$BAK"
trap - ERR

# --- next steps ----------------------------------------------------------------
case "$(hostname -s)" in
    docker) host=docker.lan ;;
    *) host=$(hostname -s) ;;
esac
case "$STACK" in
    upsnap|dashkiosk) deploy="./ansible_playbook.sh playbooks/core-services.yml --limit $host --tags $STACK" ;;
    container-mgmt) deploy="./ansible_playbook.sh playbooks/base.yml --limit $host --tags dirs,container-mgmt" ;;
    media-system) deploy="./ansible_playbook.sh playbooks/media-services.yml --limit $host --tags media-system" ;;
    adguardhome)
        ip=$(hostname -I | awk '{print $1}')
        deploy="./ansible_playbook.sh playbooks/dns.yml --limit $host --tags adguardhome --skip-tags docker_up -e ansible_ssh_host=$ip
     then: ssh $ip 'cd $STACK_DIR && docker compose up -d'   (DNS is down, so use the IP and skip the image pull)" ;;
    *) deploy="deploy the new compose file to $STACK_DIR, then docker compose up -d" ;;
esac

cat <<EOF

✓ $STACK data is in $DST. The stack is STOPPED.

Next, from ansible/ on your laptop (copies the new compose file and starts it):
  $deploy

Then verify (docs/appdata-migration.md has per-stack checks):
  cd $STACK_DIR && docker compose ps && docker compose logs --tail 50

Rollback:
  cd $STACK_DIR && docker compose down
  mv $BAK $SRC
  cp docker-compose.yml.pre-appdata docker-compose.yml && docker compose up -d

Clean up after about a week:
  rm -rf $BAK $STACK_DIR/docker-compose.yml.pre-appdata
EOF

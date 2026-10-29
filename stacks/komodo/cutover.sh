#!/bin/sh
# One-off: host side of the Komodo v1 -> v2 Core cutover on pi01 (#6), runbook
# steps 1 and 2 in komodo/README.md. Run it before Ansible deploys the v2
# compose file. Copy it over first (Ansible hasn't put it on the host yet):
#
#   scp stacks/komodo/cutover.sh pi01.lan:
#   sudo sh cutover.sh            # show the plan and ask before doing anything
#   sudo sh cutover.sh rollback   # back to v1 from the step 1 backup
#
# It backs up the v1 database volume and stack folder, stops v1 with its own
# compose file and writes the v2 .env. Volumes are never deleted. Afterwards
# run core-services.yml --tags komodo from your laptop (printed at the end).
set -eu

STACK_DIR=/opt/stacks/komodo
BACKUP_DIR=/opt/appdata/komodo/v1-backup
V1_VOLUME=komodo_sqlite-data

die() { echo "error: $*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "run with sudo"
[ -d "$STACK_DIR" ] || die "$STACK_DIR not found"

# v1 images are ghcr.io/mbecker20/komodo (tagged :1.x, :latest or via
# ${COMPOSE_KOMODO_IMAGE_TAG}); v2 is ghcr.io/moghtech/komodo-core.
is_v1() { grep -q 'image: *ghcr.io/mbecker20/komodo:' "$STACK_DIR/docker-compose.yml"; }

# Value of KEY from the v1 .env, if set.
v1_env() { sed -n "s/^$1=//p" "$STACK_DIR/.env" 2> /dev/null | tail -1; }

rollback() {
  [ -f "$BACKUP_DIR/stack-folder/docker-compose.yml" ] ||
    die "$BACKUP_DIR/stack-folder not found; nothing to roll back to"
  docker volume inspect "$V1_VOLUME" > /dev/null 2>&1 ||
    die "volume $V1_VOLUME is gone; restore it from $BACKUP_DIR/sqlite-data.tgz first (komodo/README.md step 8)"
  echo "Plan:"
  echo "  1. docker compose down in $STACK_DIR (v2 containers; volumes kept)"
  echo "  2. copy $BACKUP_DIR/stack-folder back over $STACK_DIR (v1 compose file and .env)"
  echo "  3. docker compose up -d (v1 Core on the untouched $V1_VOLUME)"
  printf "Continue? [y/N] "
  read -r answer
  [ "$answer" = y ] || [ "$answer" = Y ] || die "aborted"

  (cd "$STACK_DIR" && docker compose down)
  cp -a "$BACKUP_DIR/stack-folder/." "$STACK_DIR/"
  (cd "$STACK_DIR" && docker compose up -d)
  cat << EOF

v1 is back. The v1 agents still run on the hosts unless step 4 removed them;
if it did, roll each one back as komodo/README.md step 4 says.
Don't run Ansible's komodo tag from main until you are ready to try again: it
would deploy v2 over this.
EOF
}

[ "${1:-}" = rollback ] && { rollback; exit 0; }
[ $# -eq 0 ] || die "usage: sudo sh $0 [rollback]"

# Preflight: refuse anything that would lose or overwrite data.
is_v1 || die "$STACK_DIR/docker-compose.yml is not the v1 file (already cut over? see 'sudo sh $0 rollback')"
docker volume inspect "$V1_VOLUME" > /dev/null 2>&1 ||
  die "volume $V1_VOLUME not found (see 'docker volume ls | grep sqlite'); not cutting over without a v1 database to back up"
[ -e "$BACKUP_DIR" ] && die "$BACKUP_DIR already exists; move it aside if it is from an earlier attempt"
command -v openssl > /dev/null || die "openssl not found (needed to generate secrets)"
VOLUME_PATH=$(docker volume inspect -f '{{ .Mountpoint }}' "$V1_VOLUME")

JWT_SECRET=$(v1_env KOMODO_JWT_SECRET)
WEBHOOK_SECRET=$(v1_env KOMODO_WEBHOOK_SECRET)

echo "Contents of $STACK_DIR:"
ls -la "$STACK_DIR"
echo
echo "Plan:"
echo "  1. docker compose down with the v1 compose file (Komodo is down until Ansible deploys v2;"
echo "     running stacks and the v1 agents are unaffected)"
echo "  2. back up $V1_VOLUME and $STACK_DIR to $BACKUP_DIR"
echo "  3. write a v2 $STACK_DIR/.env (the v1 one is in the backup)"
echo "     - new Postgres user/password (generated)"
echo "     - JWT and webhook secrets: $([ -n "$JWT_SECRET" ] && echo "kept from v1" || echo "generated")"
echo "     - first admin: you type the username and password next"
printf "Continue? [y/N] "
read -r answer
[ "$answer" = y ] || [ "$answer" = Y ] || die "aborted"

printf "Init admin username [admin]: "
read -r ADMIN_USER
ADMIN_USER=${ADMIN_USER:-admin}
trap 'stty echo; exit 1' INT TERM
stty -echo
printf "Init admin password: "
read -r ADMIN_PASSWORD
printf "\nAgain: "
read -r ADMIN_PASSWORD2
stty echo
trap - INT TERM
echo
[ -n "$ADMIN_PASSWORD" ] || die "empty password"
[ "$ADMIN_PASSWORD" = "$ADMIN_PASSWORD2" ] || die "passwords don't match; nothing changed"

(cd "$STACK_DIR" && docker compose down)

mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"
tar czf "$BACKUP_DIR/sqlite-data.tgz" -C "$VOLUME_PATH" .
cp -a "$STACK_DIR" "$BACKUP_DIR/stack-folder"
[ -s "$BACKUP_DIR/sqlite-data.tgz" ] || die "backup $BACKUP_DIR/sqlite-data.tgz is empty; v1 is stopped, start it again with: cd $STACK_DIR && docker compose up -d"
echo "Backed up to $BACKUP_DIR:"
ls -l "$BACKUP_DIR"

OWNER=$(stat -c '%U:%G' "$STACK_DIR")
umask 077
cat > "$STACK_DIR/.env" << EOF
KOMODO_DATABASE_USERNAME=komodo
KOMODO_DATABASE_PASSWORD=$(openssl rand -hex 24)
KOMODO_INIT_ADMIN_USERNAME=$ADMIN_USER
KOMODO_INIT_ADMIN_PASSWORD=$ADMIN_PASSWORD
KOMODO_JWT_SECRET=${JWT_SECRET:-$(openssl rand -hex 32)}
KOMODO_WEBHOOK_SECRET=${WEBHOOK_SECRET:-$(openssl rand -hex 32)}
EOF
chmod 600 "$STACK_DIR/.env" # umask only covers new files; v1's .env was 0644
chown "$OWNER" "$STACK_DIR/.env"
echo "Wrote $STACK_DIR/.env"

cat << EOF

Done. Next (runbook step 2), from ansible/ on your laptop:
  ./ansible_playbook.sh playbooks/core-services.yml --limit pi01 --tags komodo
Then on pi01: cd $STACK_DIR && docker compose ps && docker compose logs core | tail -50
Log in at http://komodo.lan.nathancj.com as $ADMIN_USER and change the password.
Once logged in, blank KOMODO_INIT_ADMIN_PASSWORD in $STACK_DIR/.env (it is only used on an empty DB).
If the webhook secret changed, update any GitHub webhooks that use it.

Rollback (any time before runbook step 8): sudo sh $0 rollback
EOF

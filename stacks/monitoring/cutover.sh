#!/bin/sh
# One-off: hand the monitoring stack from Ansible (~/monitoring) to Komodo (#7).
# Run on pi01 after the PR adding stacks/monitoring/ is merged:
#
#   sudo sh cutover.sh            # show the plan and ask before doing anything
#
# Only Uptime Kuma's data moves (out of /opt/stacks/monitoring, which Komodo
# clones the repo into). Prometheus (/mnt/data1/monitoring-data/prometheus) and
# Grafana (volume monitoring_grafana_data) stay where they are.
#
# Afterwards: run the homelab sync in Komodo, then deploy the monitoring stack.
set -eu

STACK_DIR=/opt/stacks/monitoring
OLD_DATA=$STACK_DIR/uptimekuma_data
NEW_DATA=/mnt/data1/monitoring-data/uptime-kuma
BACKUP_DIR=${SUDO_USER:+/home/$SUDO_USER}
BACKUP=${BACKUP_DIR:-$HOME}/uptimekuma-backup-$(date +%Y%m%d-%H%M%S).tgz
GRAFANA_VOLUME=monitoring_grafana_data

die() { echo "error: $*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "run with sudo"

# Preflight: refuse anything that would lose or overwrite data.
[ -d "$STACK_DIR/.git" ] && die "$STACK_DIR is already a git checkout (already cut over?)"
[ -d "$OLD_DATA" ] || die "$OLD_DATA not found; nothing to move"
[ -e "$NEW_DATA" ] && die "$NEW_DATA already exists; not overwriting it"
[ -e "$STACK_DIR.ansible-bak" ] && die "$STACK_DIR.ansible-bak already exists"
docker volume inspect "$GRAFANA_VOLUME" > /dev/null 2>&1 ||
  die "volume $GRAFANA_VOLUME not found (see 'docker volume ls | grep grafana'); the new stack would start Grafana empty"

echo "Contents of $STACK_DIR:"
ls -la "$STACK_DIR"
echo
echo "Plan:"
echo "  1. back up $OLD_DATA to $BACKUP"
echo "  2. stop the 'monitoring' compose project (monitoring is down until Komodo deploys it)"
echo "  3. move $OLD_DATA to $NEW_DATA"
echo "  4. move $STACK_DIR to $STACK_DIR.ansible-bak"
printf "Continue? [y/N] "
read -r answer
[ "$answer" = y ] || [ "$answer" = Y ] || die "aborted"

tar czf "$BACKUP" -C "$STACK_DIR" uptimekuma_data
[ -n "${SUDO_USER:-}" ] && chown "$SUDO_USER" "$BACKUP"
echo "Backed up to $BACKUP"

# By project name, so it works whether or not ~/monitoring is still there.
docker compose -p monitoring down

mkdir -p "$(dirname "$NEW_DATA")"
mv "$OLD_DATA" "$NEW_DATA"
mv "$STACK_DIR" "$STACK_DIR.ansible-bak"

cat <<EOF

Done. Next, in Komodo:
  0. Settings -> Variables: secret variables GRAFANA_ADMIN_PASSWORD and
     HOME_ASSISTANT_TOKEN must exist (the stack's environment references them).
  1. Syncs -> homelab: Refresh, check Pending (monitoring switches to git), Execute.
  2. Stacks -> monitoring -> Deploy (or Actions -> Deploy -> stack monitoring, ref main).
Then check Grafana, Prometheus targets (incl. homeassistant_sensors) and Uptime Kuma.
Once happy: rm -r ~/monitoring $STACK_DIR.ansible-bak $BACKUP

Rollback (before Komodo deploys anything):
  sudo mv $STACK_DIR.ansible-bak $STACK_DIR && sudo mv $NEW_DATA $OLD_DATA
  cd ~/monitoring && docker compose up -d
EOF

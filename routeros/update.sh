#!/usr/bin/env bash
# Orchestrate a full RouterOS upgrade: pre-flight, backup, install, wait for reboot, firmware upgrade,
# wait for the second reboot, then post-checks.
#
#   ./update.sh -n                      # pre-flight only: versions, free space, what would happen
#   ./update.sh                         # full upgrade on the stable channel (asks first)
#   ./update.sh --channel long-term     # use the long-term channel instead
#   ./update.sh --skip-backup           # if you just ran ./backup.sh yourself
#
# Passwords come from 1Password through `op` (item ROUTER_OP_ITEM, default "Mikrotik Router").
# Note: even -n sets the router's update channel, because check-for-updates needs it.
# The whole house is offline while the router reboots (about 2-5 minutes, twice).
set -euo pipefail

host="${ROUTER_HOST:-router.lan}"
user="${ROUTER_USER:-admin}"
item="${ROUTER_OP_ITEM:-Mikrotik Router}"
channel=stable
dry_run=0
skip_backup=0

die() { echo "ERROR: $*" >&2; exit 1; }
usage() { sed -n '2,11p' "$0"; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    -n) dry_run=1 ;;
    --channel) channel="${2:-}"; shift ;;
    --skip-backup) skip_backup=1 ;;
    -h|--help) usage 0 ;;
    *) echo "unknown option: $1" >&2; usage 2 ;;
  esac
  shift
done
case "$channel" in stable|long-term) ;; *) die "channel must be stable or long-term" ;; esac
command -v op >/dev/null || die "1Password CLI (op) not found"

here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d)"
trap 'rm -f "$tmp/askpass"; rmdir "$tmp" 2>/dev/null || true' EXIT
printf '#!/bin/sh\nexec op item get %q --fields label=password\n' "$item" > "$tmp/askpass"
chmod 700 "$tmp/askpass"
export SSH_ASKPASS="$tmp/askpass" SSH_ASKPASS_REQUIRE=force
opts=(-o PubkeyAuthentication=no -o NumberOfPasswordPrompts=1 -o ConnectTimeout=5
      -o ServerAliveInterval=5 -o ServerAliveCountMax=2)

# Keep the Mac awake while we wait on the router.
if command -v caffeinate >/dev/null; then caffeinate -i -w $$ & fi

rsh()     { ssh "${opts[@]}" "$user@$host" "$@" </dev/null | tr -d '\r'; }
rsh_yes() { printf 'y\n' | ssh "${opts[@]}" "$user@$host" "$@" | tr -d '\r'; }
get()     { rsh ":put [$1]"; }
version() { get '/system resource get version' | awk '{print $1}'; }

wait_down() {  # wait up to $1 seconds for the router to stop answering ping
  local waited=0
  while ping -c1 -W1000 "$host" >/dev/null 2>&1; do
    sleep 2; waited=$((waited + 2))
    if [ "$waited" -ge "$1" ]; then return 1; fi
  done
}
wait_up() {  # wait up to $1 seconds for ssh to work again
  local waited=0
  until rsh ':put ok' >/dev/null 2>&1; do
    sleep 5; waited=$((waited + 5))
    if [ "$waited" -ge "$1" ]; then return 1; fi
    printf '.'
  done
  echo
}

echo "==> pre-flight on $user@$host (channel: $channel)"
installed_before="$(version)"
free_raw="$(get '/system resource get free-hdd-space')"
echo "    version: $installed_before   free flash: $free_raw"
case "$free_raw" in
  *MiB) free_mib="${free_raw%%.*}" ;;
  *[!0-9]*) free_mib="" ;;
  *) free_mib=$((free_raw / 1048576)) ;;
esac
if [ -n "$free_mib" ] && [ "$free_mib" -lt 40 ]; then die "only ${free_mib}MiB free flash; free some space first"; fi

rsh "/system package update set channel=$channel; /system package update check-for-updates" >/dev/null
for _ in $(seq 1 15); do
  status="$(get '/system package update get status')"
  case "$status" in ""|*finding*|*hecking*) sleep 2 ;; *) break ;; esac
done
latest="$(get '/system package update get latest-version')"
[ -n "$latest" ] || die "could not determine the latest version (status: $status)"
echo "    latest on $channel: $latest   ($status)"

fw_cur="$(get '/system routerboard get current-firmware')"
fw_up="$(get '/system routerboard get upgrade-firmware')"
echo "    firmware: $fw_cur (upgrade offers $fw_up)"

do_os=1; [ "$installed_before" = "$latest" ] && do_os=0
if [ "$do_os" -eq 0 ] && [ "$fw_cur" = "$fw_up" ]; then echo "Already on $latest with current firmware. Nothing to do."; exit 0; fi

echo
echo "Plan:"
[ "$skip_backup" -eq 0 ] && echo "  1. backup (./backup.sh pre-upgrade-$installed_before)"
[ "$do_os" -eq 1 ] && echo "  2. install RouterOS $installed_before -> $latest, router reboots, wait for it to return"
echo "  3. routerboard firmware upgrade if needed, second reboot, wait again"
echo "  4. post-checks"
if [ "$dry_run" -eq 1 ]; then echo "dry run, nothing changed"; exit 0; fi

printf '\nThe network will drop twice. Continue? [y/N] '
read -r answer
[ "$answer" = "y" ] || { echo "aborted"; exit 1; }

if [ "$skip_backup" -eq 0 ]; then
  echo "==> backup"
  "$here/backup.sh" "pre-upgrade-$installed_before"
fi

if [ "$do_os" -eq 1 ]; then
  echo "==> installing $latest (the router downloads it, then reboots by itself)"
  rsh '/system package update install' || true
  echo "    waiting for the router to go down..."
  wait_down 600 || die "router never rebooted within 10 minutes; check it by hand (nothing was changed after the install command)"
  echo "    down. waiting for it to come back (up to 15 min)"
  wait_up 900 || die "router did not come back within 15 minutes; check power/LEDs and use Winbox MAC or Netinstall if needed"
  now="$(version)"
  [ "$now" = "$latest" ] || die "router is on $now, expected $latest"
  echo "    RouterOS is now $now"
fi

fw_cur="$(get '/system routerboard get current-firmware')"
fw_up="$(get '/system routerboard get upgrade-firmware')"
if [ "$fw_cur" != "$fw_up" ]; then
  echo "==> firmware $fw_cur -> $fw_up, then reboot"
  rsh_yes '/system routerboard upgrade' || true
  sleep 5
  rsh_yes '/system reboot' || true
  wait_down 120 || die "router did not reboot after the firmware upgrade"
  wait_up 900 || die "router did not come back after the firmware reboot"
  fw_now="$(get '/system routerboard get current-firmware')"
  [ "$fw_now" = "$fw_up" ] || echo "WARNING: firmware is $fw_now, expected $fw_up; run /system routerboard upgrade by hand"
else
  echo "==> firmware already current ($fw_cur)"
fi

echo "==> post-checks"
echo "version:  $(version)    firmware: $(get '/system routerboard get current-firmware')    uptime: $(get '/system resource get uptime')"
echo "--- services";  rsh '/ip service print terse'
echo "--- port forwards"; rsh '/ip firewall nat print terse where chain=dstnat'
echo "--- router ping to the internet"; rsh '/ping 1.1.1.1 count=3' || true
code="$(curl -s -m8 -o /dev/null -w '%{http_code}' https://www.cloudflare.com || true)"
echo "--- from this Mac: https://www.cloudflare.com -> HTTP $code"

cat <<DONE

Upgrade finished. Still to check by hand: the public site (through Cloudflare), Plex remote access,
WireGuard, AdGuard/DNS on the LAN, routeros_web.
Then apply the hardening:  ./apply.sh changes/2026-10-07-hardening.rsc
Rollback if needed:  /system package downgrade   or   /system backup load name=pre-upgrade-$installed_before-<date>
DONE

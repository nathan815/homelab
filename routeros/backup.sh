#!/usr/bin/env bash
# Take an encrypted .backup and a readable .rsc export on the router, then copy both to this Mac.
#
#   ./backup.sh pre-upgrade        # -> routeros/backups/pre-upgrade-<date>.backup and .rsc
#
# Router password and backup password come from the 1Password item (ROUTER_OP_ITEM, default
# "Mikrotik Router", fields "password" and "backup password"). Nothing is written to disk.
# Output goes to routeros/backups/ (git-ignored; override with ROUTER_BACKUP_DIR).
set -euo pipefail

host="${ROUTER_HOST:-router.lan}"
user="${ROUTER_USER:-admin}"
item="${ROUTER_OP_ITEM:-Mikrotik Router}"
dest="${ROUTER_BACKUP_DIR:-$(cd "$(dirname "$0")" && pwd)/backups}"
name="${1:-manual}-$(date +%F)"

command -v op >/dev/null || { echo "1Password CLI (op) not found" >&2; exit 1; }
backup_pw="$(op item get "$item" --fields label="backup password")"
[ -n "$backup_pw" ] || { echo "backup password field is empty" >&2; exit 1; }

# Quote for a RouterOS double-quoted string.
rq="${backup_pw//\\/\\\\}"; rq="${rq//\"/\\\"}"; rq="${rq//\$/\\\$}"

tmp="$(mktemp -d)"
trap 'rm -f "$tmp/askpass"; rmdir "$tmp" 2>/dev/null || true' EXIT
printf '#!/bin/sh\nexec op item get %q --fields label=password\n' "$item" > "$tmp/askpass"
chmod 700 "$tmp/askpass"
export SSH_ASKPASS="$tmp/askpass" SSH_ASKPASS_REQUIRE=force
opts=(-o PubkeyAuthentication=no -o NumberOfPasswordPrompts=1 -o ConnectTimeout=10)

echo "==> creating $name.backup and $name.rsc on $host"
ssh "${opts[@]}" "$user@$host" "/system backup save name=$name password=\"$rq\"; /export file=$name; :delay 3s; /file print terse where name~\"$name\""

mkdir -p "$dest"
echo "==> copying to $dest"
scp "${opts[@]}" "$user@$host:$name.backup" "$user@$host:$name.rsc" "$dest/"
ls -l "$dest/$name.backup" "$dest/$name.rsc"

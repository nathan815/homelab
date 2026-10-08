#!/usr/bin/env bash
# Upload and /import one or more .rsc files on the MikroTik router, in the order given.
#
#   ./apply.sh -n cloudflare-address-list.rsc changes/2026-10-07-hardening.rsc   # dry run, no connection
#   ./apply.sh    cloudflare-address-list.rsc changes/2026-10-07-hardening.rsc   # asks, then applies
#
# ROUTER_HOST (default router.lan) and ROUTER_USER (default admin) override the target.
# If the 1Password CLI (`op`) is installed, the password is read from the 1Password item named by
# ROUTER_OP_ITEM (default "Mikrotik Router") each time ssh asks for it. Set ROUTER_NO_OP=1 to be
# prompted by ssh instead. No secrets are stored in this file or on disk.
set -euo pipefail

host="${ROUTER_HOST:-router.lan}"
user="${ROUTER_USER:-admin}"
dry_run=0
if [ "${1:-}" = "-n" ]; then dry_run=1; shift; fi
[ $# -gt 0 ] || { echo "usage: $0 [-n] file.rsc [file.rsc ...]" >&2; exit 2; }

cd "$(dirname "$0")"
for f in "$@"; do
  case "$f" in *.rsc) ;; *) echo "not an .rsc file: $f" >&2; exit 2 ;; esac
  [ -f "$f" ] || { echo "no such file: $f" >&2; exit 2; }
done

echo "target: $user@$host"
for f in "$@"; do echo "  import $(basename "$f")  ($(grep -cvE '^\s*(#|$)' "$f") commands)"; done
[ "$dry_run" -eq 1 ] && { echo "dry run, nothing sent"; exit 0; }

printf 'Apply to the live router? Backups are taken by the scripts themselves. [y/N] '
read -r answer
[ "$answer" = "y" ] || { echo "aborted"; exit 1; }

tmp="$(mktemp -d)"
ctl="$tmp/ssh"
if command -v op >/dev/null 2>&1 && [ -z "${ROUTER_NO_OP:-}" ]; then
  item="${ROUTER_OP_ITEM:-Mikrotik Router}"
  # ssh runs this helper whenever it needs the password; it only calls op, nothing is cached.
  printf '#!/bin/sh\nexec op item get %q --fields label=password\n' "$item" > "$tmp/askpass"
  chmod 700 "$tmp/askpass"
  export SSH_ASKPASS="$tmp/askpass" SSH_ASKPASS_REQUIRE=force
  echo "password: from 1Password item \"$item\""
fi
ssh_opts=(-o ControlMaster=auto -o ControlPath="$ctl" -o ControlPersist=60 -o ConnectTimeout=10)
trap 'ssh "${ssh_opts[@]}" -O exit "$user@$host" 2>/dev/null || true; rm -rf "$tmp"' EXIT

for f in "$@"; do
  name="$(basename "$f")"
  echo "==> uploading $name"
  scp "${ssh_opts[@]}" "$f" "$user@$host:$name"
  echo "==> importing $name"
  out="$(ssh "${ssh_opts[@]}" "$user@$host" "/import file-name=$name" 2>&1)" || true
  echo "$out"
  if grep -qiE "error|failure|bad command|invalid|no such item|expected" <<<"$out"; then
    echo "import of $name reported an error; stopping. Check the router before continuing." >&2
    exit 1
  elif ! grep -q "executed successfully" <<<"$out"; then
    echo "note: no success message from the router for $name (no error either); verify it applied." >&2
  fi
done
echo "done"

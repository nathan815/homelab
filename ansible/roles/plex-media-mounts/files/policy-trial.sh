#!/bin/bash
# Throwaway mergerfs create-policy test (see ../README.md for results).
# Uses only two tiny loop-mounted images under /var/tmp. Never touches /media/plexmedia01,
# /mnt/disk*, or any real drive. Cleans up after itself (also on error / Ctrl-C).
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "run with: sudo bash $0"; exit 1; }

W=/var/tmp/mgtest
VER=2.40.2
DEB_URL="https://github.com/trapexit/mergerfs/releases/download/${VER}/mergerfs_${VER}.debian-bookworm_amd64.deb"

teardown_mounts() {
  set +e
  for m in "$W/pool" "$W/a" "$W/b"; do mountpoint -q "$m" && umount "$m"; done
  set -e
}
cleanup() {
  set +e
  teardown_mounts
  # only delete the scratch dir if every mount is really gone
  if ! mountpoint -q "$W/pool" && ! mountpoint -q "$W/a" && ! mountpoint -q "$W/b"; then
    rm -rf "$W"
  else
    echo "WARNING: something is still mounted under $W; left in place, nothing deleted"
  fi
}
trap cleanup EXIT

if ! command -v mergerfs >/dev/null; then
  echo ">> installing mergerfs ${VER}"
  curl -fL -o /var/tmp/mergerfs-trial.deb "$DEB_URL"
  apt-get install -y /var/tmp/mergerfs-trial.deb
  rm -f /var/tmp/mergerfs-trial.deb
fi
mergerfs --version | head -1

pool_mount() { # $1=policy $2=minfreespace
  mergerfs -o "allow_other,use_ino,cache.files=off,category.create=$1,moveonenospc=true,minfreespace=$2" \
    "$W/a:$W/b" "$W/pool"
}
where() { # which fake disk holds each given relative path
  for p in "$@"; do
    for d in a b; do
      if [ -e "$W/$d/$p" ]; then printf '   %-28s -> disk %s (%s bytes)\n' "$p" "$d" "$(stat -c %s "$W/$d/$p")"; fi
    done
  done
  return 0
}

run() {
  pol=$1
  echo; echo "================ policy: $pol ================"
  rm -rf "$W"; mkdir -p "$W/a" "$W/b" "$W/pool"
  truncate -s 20M "$W/a.img"; truncate -s 50M "$W/b.img"      # a = "old full-ish drive", b = "new drive"
  mkfs.ext4 -q -m 0 -F "$W/a.img"; mkfs.ext4 -q -m 0 -F "$W/b.img"
  mount -o loop "$W/a.img" "$W/a"; mount -o loop "$W/b.img" "$W/b"
  # layout like your real drives: the old drive has the existing show; TV and Movies exist on both
  mkdir -p "$W/a/TV/LongShow" "$W/b/TV" "$W/a/Movies" "$W/b/Movies"

  pool_mount "$pol" 5M

  echo "-- 1. brand-new show in TV (expect disk b, the emptier one)"
  mkdir -p "$W/pool/TV/NewShow"; echo x > "$W/pool/TV/NewShow/e1"; where TV/NewShow/e1

  echo "-- 2. new episode of existing show, disk a has room (expect disk a)"
  echo x > "$W/pool/TV/LongShow/e1"; where TV/LongShow/e1

  echo "-- 3. brand-new TOP-LEVEL folder that exists on neither disk (epmfs footgun check)"
  mkdir -p "$W/pool/Anime/Show" && echo x > "$W/pool/Anime/Show/e1" || echo "   FAILED to create"; where Anime/Show/e1

  echo "-- 4. disk a nearly full (below minfreespace 5M): new episode of existing show"
  avail=$(df -B1M --output=avail "$W/a" | tail -1 | tr -d ' ')
  fallocate -l "$((avail - 3))M" "$W/a/filler"
  echo "   disk a free now: $(df -B1M --output=avail "$W/a" | tail -1 | tr -d ' ')M"
  dd if=/dev/zero of="$W/pool/TV/LongShow/e2" bs=1M count=2 status=none || echo "   FAILED to write"; where TV/LongShow/e2

  echo "-- 5. disk a above minfreespace but too small for the file (mid-write ENOSPC, minfreespace=1M, 10M file)"
  umount "$W/pool"; pool_mount "$pol" 1M
  dd if=/dev/zero of="$W/pool/TV/LongShow/e3" bs=1M count=10 status=none || echo "   FAILED to write"; where TV/LongShow/e3

  teardown_mounts
}

run epmfs
run mspmfs
echo; echo "done; cleaning up"

#!/usr/bin/env bash
# Spike Step 2: create two 2 GB disk images (NTFS + ext4) and print their device nodes.
# Disk images only: nothing here touches a real drive.
set -euo pipefail

usage() {
  echo "usage: $0 [--force]" >&2
  echo "  Creates build/spike/ntfs.dmg and build/spike/ext.dmg, attaches them with -nomount," >&2
  echo "  formats the data partitions (mkntfs / mkfs.ext4) and prints the device nodes." >&2
  echo "  Refuses to run if the images already exist unless --force is given." >&2
  exit 2
}

FORCE=0
case "${1:-}" in
  "") ;;
  --force) FORCE=1 ;;
  *) usage ;;
esac
[[ $# -le 1 ]] || usage

export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/opt/homebrew/opt/e2fsprogs/bin:/opt/homebrew/opt/e2fsprogs/sbin:/usr/local/bin:/usr/local/sbin:$PATH"

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$ROOT/build/spike"
NTFS_IMG="$OUT/ntfs.dmg"
EXT_IMG="$OUT/ext.dmg"
mkdir -p "$OUT"

for tool in mkntfs mkfs.ext4; do
  command -v "$tool" >/dev/null || { echo "error: $tool not found (see README step 1: brew installs)" >&2; exit 1; }
done

# Print the whole-disk node (e.g. /dev/disk4) an image is attached as, or nothing.
attached_dev() {
  hdiutil info | awk -v p="$1" '
    /^image-path/ { inimg = (index($0, p) > 0) }
    inimg && $1 ~ /^\/dev\/disk[0-9]+$/ { print $1; exit }'
}

for img in "$NTFS_IMG" "$EXT_IMG"; do
  if [[ -e "$img" ]]; then
    if [[ $FORCE -ne 1 ]]; then
      echo "error: $img already exists. Re-run with --force to replace it." >&2
      exit 1
    fi
    dev="$(attached_dev "$img")"
    if [[ -n "$dev" ]]; then
      echo "Detaching $dev (old $(basename "$img"))"
      hdiutil detach -force "$dev" >/dev/null
    fi
    rm -f "$img"
  fi
done

# Run a command as-is if we can write the device, otherwise via sudo.
run_on_dev() {
  local dev="$1"; shift
  if [[ -w "$dev" ]]; then "$@"; else sudo "$@"; fi
}

# make_image <image> <mkfs command...>   (the data partition is appended as last arg)
make_image() {
  local img="$1"; shift
  echo "==> Creating $img"
  hdiutil create -size 2g -layout GPTSPUD -fs ExFAT -volname SPIKE "$img" >/dev/null

  echo "==> Attaching $img (-nomount)"
  local attach_out whole part
  attach_out="$(hdiutil attach -nomount "$img")"
  echo "$attach_out"

  whole="$(echo "$attach_out" | awk '$1 ~ /^\/dev\/disk[0-9]+$/ { print $1; exit }')"
  # Data partition = last /dev/diskNsM line that is not the EFI partition.
  part="$(echo "$attach_out" | awk '$1 ~ /^\/dev\/disk[0-9]+s[0-9]+$/ && $0 !~ /EFI/ { p = $1 } END { print p }')"
  if [[ -z "$part" ]]; then
    echo "error: could not find the data partition in the attach output above" >&2
    exit 1
  fi

  echo "==> Formatting $part: $*"
  run_on_dev "$part" "$@" "$part"

  # Remember the nodes for the other spike scripts (daemon-mount.sh reads these).
  echo "$whole" > "${img%.dmg}.disk"
  echo "$part" > "${img%.dmg}.dev"
}

make_image "$NTFS_IMG" mkntfs --quick --label SPIKE
make_image "$EXT_IMG" mkfs.ext4 -F -L SPIKEEXT

echo
echo "Done. Device nodes:"
echo "  NTFS: whole disk $(cat "$OUT/ntfs.disk"), data partition $(cat "$OUT/ntfs.dev")"
echo "  ext4: whole disk $(cat "$OUT/ext.disk"), data partition $(cat "$OUT/ext.dev")"
echo
echo "Next: scripts/spike/ntfs-roundtrip.sh $(cat "$OUT/ntfs.dev")"
echo "Detach later with: hdiutil detach $(cat "$OUT/ntfs.disk"); hdiutil detach $(cat "$OUT/ext.disk")"

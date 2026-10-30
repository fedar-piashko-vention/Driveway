#!/usr/bin/env bash
# Spike Step 3 (risk 1): mount NTFS via ntfs-3g on macFUSE FSKit, write 1 GB + 2,000 small
# files, hash, unmount, remount, re-hash, compare. Prints PASS or FAIL.
set -euo pipefail

usage() {
  echo "usage: $0 [--keep-mounted] <dev>" >&2
  echo "  <dev> is the NTFS data partition from make-images.sh, e.g. /dev/disk4s2" >&2
  exit 2
}

KEEP=0
if [[ "${1:-}" == "--keep-mounted" ]]; then KEEP=1; shift; fi
[[ $# -eq 1 && "$1" == /dev/* ]] || usage
DEV="$1"

export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin:$PATH"
command -v ntfs-3g >/dev/null || { echo "error: ntfs-3g not found" >&2; exit 1; }

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LOGDIR="$ROOT/build/spike/logs"
mkdir -p "$LOGDIR"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="$LOGDIR/ntfs-roundtrip-$STAMP.log"
MP=/Volumes/SPIKE
SMALL_COUNT=2000

# Tee everything we print into the log too.
exec > >(tee -a "$LOG") 2>&1
echo "Log: $LOG"
echo "Device: $DEV   Mountpoint: $MP   $(date)"
ntfs-3g --version 2>&1 || true

# mount_ntfs <label>: runs the spike's mount, records exit code + stderr in the log.
mount_ntfs() {
  local label="$1" errfile rc
  errfile="$LOGDIR/ntfs-mount-$label-$STAMP.stderr"
  echo "--- mount ($label): sudo ntfs-3g $DEV $MP -o backend=fskit,volname=SPIKE,uid=$(id -u),gid=$(id -g)"
  set +e
  sudo ntfs-3g "$DEV" "$MP" -o "backend=fskit,volname=SPIKE,uid=$(id -u),gid=$(id -g)" 2>"$errfile"
  rc=$?
  set -e
  echo "ntfs-3g exit code: $rc"
  echo "ntfs-3g stderr ($errfile):"
  sed 's/^/    /' "$errfile"
  # Options that were rejected or ignored usually show up as one of these words.
  if grep -iE 'unknown|unsupported|not implemented|not supported|ignor|invalid|deprecated' "$errfile" >/dev/null; then
    echo "NOTE: stderr mentions rejected/ignored options (copy those lines into docs/spike-results.md)"
  fi
  if [[ $rc -ne 0 ]]; then
    if [[ ! -d "$MP" ]]; then
      echo "NOTE: $MP does not exist. Creating it with sudo mkdir and retrying once."
      sudo mkdir -p "$MP"
      set +e
      sudo ntfs-3g "$DEV" "$MP" -o "backend=fskit,volname=SPIKE,uid=$(id -u),gid=$(id -g)" 2>"$errfile.retry"
      rc=$?
      set -e
      echo "retry exit code: $rc"
      sed 's/^/    /' "$errfile.retry"
    fi
  fi
  [[ $rc -eq 0 ]] || { echo "FAIL: mount ($label) failed"; exit 1; }
  sleep 2
  echo "mount table:"; mount | grep -F "$MP" || echo "    (no entry for $MP in 'mount' output!)"
  echo "ls -ld $MP: $(ls -ld "$MP")"
}

# hash_all: one sha256 line per file we wrote, sorted by path.
hash_all() {
  (cd "$MP" && find roundtrip -type f | LC_ALL=C sort | while IFS= read -r f; do shasum -a 256 "$f"; done)
}

mount_ntfs first

echo "--- writing 1 GB of random data (dd bs=1m count=1024 from /dev/urandom)"
mkdir -p "$MP/roundtrip/small"
dd if=/dev/urandom of="$MP/roundtrip/random.bin" bs=1m count=1024 2>&1 | tail -n 1

echo "--- writing $SMALL_COUNT small files"
for i in $(seq 1 "$SMALL_COUNT"); do
  head -c $(( (RANDOM % 8192) + 1 )) /dev/urandom > "$MP/roundtrip/small/f$i.bin"
done

echo "--- ownership check (does uid=$(id -u) apply?)"
ls -ln "$MP/roundtrip/random.bin" "$MP/roundtrip/small/f1.bin"
echo "expected owner: $(id -un) ($(id -u))"

echo "--- hashing (before unmount)"
sync
hash_all > "$LOGDIR/hashes-before-$STAMP.txt"
wc -l < "$LOGDIR/hashes-before-$STAMP.txt" | sed 's/^ *//; s/$/ files hashed/'

echo "--- unmount"
sync
if ! umount "$MP"; then
  echo "plain umount failed, retrying with sudo"
  sudo umount "$MP"
fi
sleep 2
mount | grep -F "$MP" && { echo "FAIL: still mounted after umount"; exit 1; } || true

mount_ntfs second

echo "--- hashing (after remount)"
hash_all > "$LOGDIR/hashes-after-$STAMP.txt"

RESULT=PASS
if ! diff -u "$LOGDIR/hashes-before-$STAMP.txt" "$LOGDIR/hashes-after-$STAMP.txt" > "$LOGDIR/hashes-diff-$STAMP.txt"; then
  RESULT=FAIL
  echo "Hash differences (first 20 lines):"; head -n 20 "$LOGDIR/hashes-diff-$STAMP.txt"
fi
# Expect exactly 1 + SMALL_COUNT files.
COUNT="$(wc -l < "$LOGDIR/hashes-after-$STAMP.txt" | tr -d ' ')"
if [[ "$COUNT" -ne $((SMALL_COUNT + 1)) ]]; then
  RESULT=FAIL
  echo "Expected $((SMALL_COUNT + 1)) files, found $COUNT"
fi

if [[ $KEEP -eq 1 ]]; then
  echo "--- leaving $MP mounted (--keep-mounted). Unmount later with: umount $MP || sudo umount $MP"
else
  echo "--- unmount"
  sync
  umount "$MP" || sudo umount "$MP"
fi

echo
echo "$RESULT: ntfs round trip ($((SMALL_COUNT + 1)) files, 1 GB random.bin, hashes compared across remount)"
echo "Record in docs/spike-results.md: exit codes, stderr, rejected/ignored options. Full log: $LOG"
[[ "$RESULT" == PASS ]]

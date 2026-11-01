#!/usr/bin/env bash
# Spike Step 8: throughput on a mounted volume. Prints one markdown table row.
#   Writable mount:  dd write 4096 MB, dd read back, cp -R of 10,000 files (4-64 KB).
#   --read-only:     read-only mount (e.g. macOS native NTFS): only the read test and a
#                    cp -R *from* the mount. Needs the data left behind by a --keep run.
set -euo pipefail

usage() {
  echo "usage: $0 [--read-only] [--keep] [--purge] [--label TEXT] <mountpoint>" >&2
  echo "  --keep       leave <mountpoint>/driveway-speed in place (so a read-only run can use it)" >&2
  echo "  --purge      run 'sudo purge' before the read tests to drop the page cache" >&2
  echo "  --label TEXT first column of the result row (default: the mountpoint)" >&2
  exit 2
}

RO=0; KEEP=0; PURGE=0; LABEL=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --read-only) RO=1; shift ;;
    --keep) KEEP=1; shift ;;
    --purge) PURGE=1; shift ;;
    --label) [[ $# -ge 2 ]] || usage; LABEL="$2"; shift 2 ;;
    -*) usage ;;
    *) break ;;
  esac
done
[[ $# -eq 1 && -d "$1" ]] || usage
MP="${1%/}"
[[ -n "$LABEL" ]] || LABEL="$MP"

WORK="$MP/driveway-speed"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/driveway-speed.XXXXXX")"
trap 'rm -rf "$TMP"; if [[ $RO -eq 0 && $KEEP -eq 0 ]]; then rm -rf "$WORK"; fi' EXIT

now() { perl -MTime::HiRes=time -e 'printf "%.3f\n", time'; }
# rate <MB> <seconds>
rate() { awk -v mb="$1" -v s="$2" 'BEGIN { printf "%.1f", mb / s }'; }
drop_cache() { if [[ $PURGE -eq 1 ]]; then sudo purge; fi; }

BIG_MB="${BIG_MB:-4096}"   # override only for dry runs
NFILES="${NFILES:-10000}"

WRITE_MBS="n/a"; CP_S="n/a"

if [[ $RO -eq 0 ]]; then
  mkdir -p "$WORK"
  echo "--- sustained write: dd bs=1m count=$BIG_MB" >&2
  t0="$(now)"
  dd if=/dev/zero of="$WORK/big" bs=1m count="$BIG_MB" 2>/dev/null
  sync
  t1="$(now)"
  WRITE_MBS="$(rate "$BIG_MB" "$(awk -v a="$t0" -v b="$t1" 'BEGIN { print b - a }')")"

  echo "--- generating $NFILES source files (4-64 KB) in $TMP/src" >&2
  mkdir -p "$TMP/src"
  perl -e '
    my ($dir, $n) = @ARGV;
    open(my $r, "<", "/dev/urandom") or die; read($r, my $buf, 131072); close $r;
    for my $i (1 .. $n) {
      my $size = 4096 + int(rand(61441));
      my $off  = int(rand(length($buf) - $size));
      open(my $o, ">", "$dir/f$i.bin") or die "$dir/f$i.bin: $!";
      print $o substr($buf, $off, $size);
      close $o;
    }' "$TMP/src" "$NFILES"

  echo "--- cp -R of $NFILES files onto the volume" >&2
  t0="$(now)"
  cp -R "$TMP/src" "$WORK/small"
  sync
  t1="$(now)"
  CP_S="$(awk -v a="$t0" -v b="$t1" 'BEGIN { printf "%.1f", b - a }')"
else
  [[ -f "$WORK/big" && -d "$WORK/small" ]] || { echo "error: $WORK/big or $WORK/small missing. Run a writable pass with --keep first." >&2; exit 1; }
  echo "--- cp -R of the folder from the volume to local disk" >&2
  drop_cache
  t0="$(now)"
  cp -R "$WORK/small" "$TMP/dst"
  t1="$(now)"
  CP_S="$(awk -v a="$t0" -v b="$t1" 'BEGIN { printf "%.1f", b - a }')"
fi

echo "--- sustained read: dd bs=1m" >&2
drop_cache
t0="$(now)"
dd if="$WORK/big" of=/dev/null bs=1m 2>/dev/null
t1="$(now)"
READ_MBS="$(rate "$BIG_MB" "$(awk -v a="$t0" -v b="$t1" 'BEGIN { print b - a }')")"

echo >&2
echo "| mount | write MB/s ($BIG_MB MB) | read MB/s | cp -R $NFILES files (s) |"
echo "|---|---|---|---|"
echo "| $LABEL | $WRITE_MBS | $READ_MBS | $CP_S |"
if [[ $PURGE -eq 0 ]]; then
  echo "(read figures may be served from the page cache; use --purge for cold reads)" >&2
fi

#!/usr/bin/env bash
# Spike Step 4: the one-shot script run by spike-daemon.plist as root.
# Mounts the NTFS image with ntfs-3g (FSKit backend), uid/gid = the console user, and logs.
# Can also be run by hand:  sudo scripts/spike/daemon-mount.sh [/dev/diskNsM]
set -euo pipefail

usage() {
  echo "usage: $0 [<dev>]   (default dev: contents of build/spike/ntfs.dev)" >&2
  exit 2
}
[[ $# -le 1 ]] || usage

# launchd gives daemons a minimal PATH.
export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin:/usr/bin:/bin:/usr/sbin:/sbin"

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LOG=/var/log/driveway-spike.log
MP=/Volumes/SPIKE
DEV="${1:-$(cat "$ROOT/build/spike/ntfs.dev" 2>/dev/null || true)}"
[[ -n "$DEV" ]] || { echo "no device given and build/spike/ntfs.dev missing" | tee -a "$LOG"; exit 2; }

log() { echo "[$(date '+%F %T')] $*" >> "$LOG"; }

# The logged-in GUI user (the owner of /dev/console), not root.
CONSOLE_UID="$(stat -f %u /dev/console)"
CONSOLE_GID="$(id -g "$CONSOLE_UID" 2>/dev/null || echo 20)"
CONSOLE_USER="$(stat -f %Su /dev/console)"

log "=== daemon-mount start: whoami=$(whoami) dev=$DEV console_user=$CONSOLE_USER uid=$CONSOLE_UID gid=$CONSOLE_GID"
log "ntfs-3g path: $(command -v ntfs-3g || echo NOT FOUND)"

ERR="$(mktemp)"
set +e
ntfs-3g "$DEV" "$MP" -o "backend=fskit,volname=SPIKE,uid=$CONSOLE_UID,gid=$CONSOLE_GID" 2>"$ERR"
RC=$?
set -e
log "ntfs-3g exit code: $RC"
log "ntfs-3g stderr: $(tr '\n' '|' < "$ERR")"
rm -f "$ERR"

if [[ $RC -ne 0 && ! -d "$MP" ]]; then
  log "$MP missing; creating it and retrying once"
  mkdir -p "$MP"
  set +e
  ntfs-3g "$DEV" "$MP" -o "backend=fskit,volname=SPIKE,uid=$CONSOLE_UID,gid=$CONSOLE_GID" 2>>"$LOG"
  RC=$?
  set -e
  log "retry exit code: $RC"
fi

if [[ $RC -eq 0 ]]; then
  sleep 2
  log "mount table: $(mount | grep -F "$MP" || echo 'NO ENTRY')"
  # Ownership probe: file created as root should still show up owned by the console user.
  touch "$MP/daemon-probe.txt" 2>>"$LOG" || log "touch failed"
  log "probe ownership: $(ls -ln "$MP/daemon-probe.txt" 2>&1)"
  log "root dir: $(ls -ldn "$MP" 2>&1)"
  log "Now check by eye: Finder sidebar shows SPIKE; 'ls -l $MP' as yourself."
fi

log "=== daemon-mount end (exit $RC)"
exit "$RC"

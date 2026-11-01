#!/usr/bin/env bash
# Spike Step 9: show FSKit modules and highlight macFUSE's, with its enabled marker (+/-).
# Run once with macFUSE's module enabled and once disabled (System Settings -> General ->
# Login Items & Extensions -> File System Extensions), passing a label each time.
set -euo pipefail

usage() {
  echo "usage: $0 [label]    e.g. $0 enabled   /   $0 disabled" >&2
  echo "  Runs: pluginkit -m -v -p com.apple.fskit.fsmodule" >&2
  exit 2
}
[[ $# -le 1 ]] || usage
LABEL="${1:-run}"

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
mkdir -p "$ROOT/build/spike/logs"
OUT="$ROOT/build/spike/logs/pluginkit-$LABEL.txt"

pluginkit -m -v -p com.apple.fskit.fsmodule | tee "$OUT" | awk '
  tolower($0) ~ /macfuse/ { printf "\033[1;33m>> %s\033[0m\n", $0; next }
  { print "   " $0 }'

echo
echo "macFUSE lines (raw, saved to $OUT):"
if grep -i macfuse "$OUT"; then
  echo
  # pluginkit prefixes elected plug-ins with + (enabled) or - (disabled); no prefix = default/not elected.
  marker="$(grep -i macfuse "$OUT" | head -n 1 | sed -E 's/^[[:space:]]*//' | cut -c1)"
  case "$marker" in
    "+"|"-"|"!"|"?") echo "Enabled marker: $marker" ;;
    *) echo "Enabled marker: (none; line has no +/- prefix)" ;;
  esac
else
  echo "(none: macFUSE FSKit module not registered)"
fi

#!/bin/bash
# Rebuilds Packaging/Driveway.icns from Packaging/Icon/gradient-source.png.
# Run after changing the gradient or scripts/make-icon.swift, then commit the .icns.
set -euo pipefail
cd "$(dirname "$0")/.."
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
swift scripts/make-icon.swift Packaging/Icon/gradient-source.png Packaging/Icon/Driveway-1024.png
SET="$WORK/Driveway.iconset"
mkdir "$SET"
for pt in 16 32 128 256 512; do
    sips -z "$pt" "$pt" Packaging/Icon/Driveway-1024.png --out "$SET/icon_${pt}x${pt}.png" >/dev/null
    px=$((pt * 2))
    sips -z "$px" "$px" Packaging/Icon/Driveway-1024.png --out "$SET/icon_${pt}x${pt}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o Packaging/Driveway.icns
echo "Wrote Packaging/Driveway.icns"

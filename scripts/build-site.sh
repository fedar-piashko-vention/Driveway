#!/bin/bash
# Assembles the website from site/ plus the README's screenshots, so the images live in one place.
# Usage: scripts/build-site.sh [output-dir]   (default: build/site)
set -euo pipefail

cd "$(dirname "$0")/.."
out="${1:-build/site}"

rm -rf "$out"
mkdir -p "$out/images"
cp site/index.html site/style.css site/site.js site/*.png "$out/"
cp docs/images/disk-manager.png docs/images/check-repair.png docs/images/setup.png \
   docs/images/finder-sidebar.png "$out/images/"
touch "$out/.nojekyll"
echo "Site built in $out"

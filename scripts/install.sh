#!/bin/bash
# Installs the latest Driveway release into /Applications and opens it. Running it again updates Driveway.
# Driveway is ad-hoc signed, so macOS calls a copy downloaded in a browser "damaged" and won't open it. A DMG that
# curl downloads isn't quarantined, and a quarantine flag on a DMG given as an argument is removed after copying.
# Usage: install.sh [path/to/Driveway-x.y.z.dmg]      (default: download the latest release from GitHub)
set -euo pipefail

REPO="fedar-piashko-vention/Driveway"
APP="/Applications/Driveway.app"

fail() { echo "Driveway: $*" >&2; exit 1; }

# Runs a command as the user, and again with sudo if that fails (Applications or the old app not writable).
as_admin() {
    "$@" 2>/dev/null && return
    echo "Your Mac's password is needed to install into Applications."
    sudo "$@"
}

[[ "$(uname -s)" == Darwin ]] || fail "this installer is for macOS."
# hw.optional.arm64 is 1 on Apple Silicon even when Terminal runs under Rosetta.
[[ "$(sysctl -in hw.optional.arm64)" == 1 ]] || fail "Driveway needs a Mac with Apple Silicon (M1 or later)."
IFS=. read -r major minor _ <<< "$(sw_vers -productVersion).0"
if (( major < 15 || (major == 15 && minor < 4) )); then
    fail "Driveway needs macOS 15.4 or later. This Mac has macOS $(sw_vers -productVersion)."
fi

WORK="$(mktemp -d)"
MOUNT="${WORK}/mnt"
cleanup() {
    [[ -d "${MOUNT}" ]] && hdiutil detach -quiet "${MOUNT}" 2>/dev/null
    rm -rf "${WORK}"
}
trap cleanup EXIT

if [[ $# -gt 0 ]]; then
    DMG="$1"
    [[ -f "${DMG}" ]] || fail "${DMG} not found."
else
    echo "Finding the latest version of Driveway..."
    # /releases/latest redirects to /releases/tag/vX.Y.Z.
    latest="$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/${REPO}/releases/latest")" ||
        fail "couldn't reach GitHub. Check your internet connection and try again."
    tag="${latest##*/}"
    [[ "${tag}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+ ]] || fail "couldn't find a released version on GitHub."
    version="${tag#v}"
    DMG="${WORK}/Driveway-${version}.dmg"
    echo "Downloading Driveway ${version}..."
    curl -fL --progress-bar -o "${DMG}" "https://github.com/${REPO}/releases/download/${tag}/Driveway-${version}.dmg" ||
        fail "the download failed. Check your internet connection and try again."
fi

mkdir "${MOUNT}"
hdiutil attach -quiet -nobrowse -readonly -noautoopen -mountpoint "${MOUNT}" "${DMG}" ||
    fail "couldn't open the downloaded file. Run this again to download it again."
# Copied out first so the quarantine flag can be removed as the user, without a password.
ditto "${MOUNT}/Driveway.app" "${WORK}/Driveway.app"
xattr -dr com.apple.quarantine "${WORK}/Driveway.app" 2>/dev/null || true
codesign --verify --deep --strict "${WORK}/Driveway.app" 2>/dev/null ||
    fail "the downloaded app is incomplete or damaged. Run this again to download it again."

if pgrep -xq Driveway; then
    echo "Closing Driveway..."
    pkill -x Driveway || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -xq Driveway || break; sleep 0.5; done
fi

echo "Installing Driveway into Applications..."
if [[ -e "${APP}" ]]; then as_admin rm -rf "${APP}"; fi
as_admin ditto "${WORK}/Driveway.app" "${APP}"

echo "Driveway is installed. Opening it..."
open "${APP}"

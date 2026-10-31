#!/bin/bash
# Builds build/Driveway.app (ad-hoc signed, hardened runtime) and build/Driveway-<version>.dmg.
# Usage: scripts/build-app.sh [version]      (default 0.0.0-dev)
set -euo pipefail

VERSION="${1:-0.0.0-dev}"
VERSION_RE='^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$'
if [[ ! "${VERSION}" =~ ${VERSION_RE} ]]; then
    echo "Invalid version '${VERSION}': expected N.N.N or N.N.N-suffix." >&2
    exit 64
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

BUILD_INFO="Sources/DrivewayIPC/BuildInfo.swift"
APP="build/Driveway.app"
AGENT_APP="${APP}/Contents/Library/LoginItems/DrivewayAgent.app"
HELPER="${APP}/Contents/Library/LaunchServices/app.driveway.helper"
DMG="build/Driveway-${VERSION}.dmg"
STAGING="build/dmg-staging"

# BuildInfo.swift is tracked; it is rewritten for this build and always restored on exit.
if ! git diff --quiet -- "${BUILD_INFO}"; then
    echo "${BUILD_INFO} has uncommitted changes; refusing to overwrite them." >&2
    exit 65
fi
restore_build_info() { git checkout -- "${BUILD_INFO}"; }
trap restore_build_info EXIT

cat > "${BUILD_INFO}" <<SWIFT
// Overwritten by scripts/build-app.sh with the app's CFBundleShortVersionString.
// The app and the helper must agree on this value; a mismatch means the helper needs updating.
public let helperProtocolVersion = "${VERSION}"
SWIFT

swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)"

rm -rf "${APP}" "${STAGING}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources" \
    "${APP}/Contents/Library/LaunchServices" \
    "${AGENT_APP}/Contents/MacOS"

cp "${BIN}/Driveway" "${APP}/Contents/MacOS/Driveway"
cp "${BIN}/DrivewayHelper" "${HELPER}"
cp "${BIN}/DrivewayAgent" "${AGENT_APP}/Contents/MacOS/DrivewayAgent"

cp Packaging/Driveway-Info.plist "${APP}/Contents/Info.plist"
cp Packaging/DrivewayAgent-Info.plist "${AGENT_APP}/Contents/Info.plist"
for plist in "${APP}/Contents/Info.plist" "${AGENT_APP}/Contents/Info.plist"; do
    plutil -replace CFBundleShortVersionString -string "${VERSION}" "${plist}"
done
plutil -replace CFBundleExecutable -string Driveway "${APP}/Contents/Info.plist"
plutil -replace CFBundleExecutable -string DrivewayAgent "${AGENT_APP}/Contents/Info.plist"

# The icon: Dock, Finder and About for the app; notifications for the agent (it posts them).
mkdir -p "${AGENT_APP}/Contents/Resources"
cp Packaging/Driveway.icns "${APP}/Contents/Resources/Driveway.icns"
cp Packaging/Driveway.icns "${AGENT_APP}/Contents/Resources/Driveway.icns"

cp Packaging/app.driveway.helper.plist Packaging/app.driveway.agent.plist \
    Packaging/install-helper.sh Packaging/uninstall-helper.sh "${APP}/Contents/Resources/"
chmod 755 "${APP}/Contents/Resources/install-helper.sh" "${APP}/Contents/Resources/uninstall-helper.sh"

# Ad-hoc sign inside-out with the hardened runtime. The helper refuses callers that
# lack the runtime flag. Only the app carries entitlements: Apple Events, so the
# osascript it starts may drive Terminal (TCC attributes those events to the app).
codesign --force --options runtime -s - --identifier app.driveway.helper "${HELPER}"
codesign --force --options runtime -s - --identifier app.driveway.agent "${AGENT_APP}"
codesign --force --options runtime -s - --identifier app.driveway.Driveway \
    --entitlements Packaging/Driveway.entitlements "${APP}"

codesign --verify --deep --strict "${APP}"
# Require the runtime flag inside the CodeDirectory flags, e.g. flags=0x10002(adhoc,runtime).
for target in "${APP}" "${AGENT_APP}" "${HELPER}"; do
    SIG="$(codesign -dv "${target}" 2>&1)"
    if [[ "${SIG}" != *flags=0x*"("*runtime*")"* ]]; then
        echo "Signature of ${target} lacks the hardened runtime flag:" >&2
        echo "${SIG}" >&2
        exit 1
    fi
done

mkdir -p "${STAGING}"
ditto "${APP}" "${STAGING}/Driveway.app"
ln -s /Applications "${STAGING}/Applications"
rm -f "${DMG}"
hdiutil create -volname Driveway -srcfolder "${STAGING}" -ov -format UDZO "${DMG}"
rm -rf "${STAGING}"

echo "Built ${APP} and ${DMG}"

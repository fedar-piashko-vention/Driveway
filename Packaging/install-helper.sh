#!/bin/bash
# Installs the Driveway privileged helper. Run as root, normally through the
# app's administrator prompt: install-helper.sh /Applications/Driveway.app
set -euo pipefail

APP="${1:-}"
EXPECTED_APP="/Applications/Driveway.app"

if [[ "${EUID}" -ne 0 ]]; then
    echo "install-helper.sh must run as root." >&2
    exit 77
fi
if [[ "${APP}" != "${EXPECTED_APP}" ]]; then
    echo "Usage: install-helper.sh ${EXPECTED_APP}" >&2
    exit 64
fi

HELPER_SRC="${APP}/Contents/Library/LaunchServices/app.driveway.helper"
RES="${APP}/Contents/Resources"
HELPER_DST="/Library/PrivilegedHelperTools/app.driveway.helper"
DAEMON_PLIST="/Library/LaunchDaemons/app.driveway.helper.plist"
AGENT_PLIST="/Library/LaunchAgents/app.driveway.agent.plist"
LOG_DIR="/Library/Logs/Driveway"

for f in "${HELPER_SRC}" "${RES}/app.driveway.helper.plist" "${RES}/app.driveway.agent.plist"; do
    if [[ ! -f "${f}" ]]; then
        echo "Missing ${f}" >&2
        exit 66
    fi
done

# The helper only trusts callers from a root-owned, non-group/other-writable bundle.
chown -R root:wheel "${APP}"
chmod -R go-w "${APP}"

install -d -o root -g wheel -m 755 /Library/PrivilegedHelperTools
install -d -o root -g wheel -m 755 "${LOG_DIR}"
install -o root -g wheel -m 755 "${HELPER_SRC}" "${HELPER_DST}"
install -o root -g wheel -m 644 "${RES}/app.driveway.helper.plist" "${DAEMON_PLIST}"
install -o root -g wheel -m 644 "${RES}/app.driveway.agent.plist" "${AGENT_PLIST}"

launchctl bootout system/app.driveway.helper 2>/dev/null || true
launchctl bootstrap system "${DAEMON_PLIST}"

CONSOLE_UID="$(stat -f %u /dev/console)"
if [[ "${CONSOLE_UID}" -ne 0 ]]; then
    launchctl bootout "gui/${CONSOLE_UID}/app.driveway.agent" 2>/dev/null || true
    launchctl bootstrap "gui/${CONSOLE_UID}" "${AGENT_PLIST}" || true
fi
echo "Driveway helper installed."

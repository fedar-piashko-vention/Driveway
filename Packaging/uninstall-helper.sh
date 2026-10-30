#!/bin/bash
# Removes the Driveway privileged helper and agent. Run as root:
#   uninstall-helper.sh [/Applications/Driveway.app]
# Settings in /Library/Application Support/Driveway are deliberately NOT deleted,
# so a reinstall keeps the owner's choices. Remove that folder by hand to reset.
set -euo pipefail

APP="${1:-/Applications/Driveway.app}"

if [[ "${EUID}" -ne 0 ]]; then
    echo "uninstall-helper.sh must run as root." >&2
    exit 77
fi

CONSOLE_UID="$(stat -f %u /dev/console)"
if [[ "${CONSOLE_UID}" -ne 0 ]]; then
    launchctl bootout "gui/${CONSOLE_UID}/app.driveway.agent" 2>/dev/null || true
fi
launchctl bootout system/app.driveway.helper 2>/dev/null || true

rm -f /Library/LaunchAgents/app.driveway.agent.plist
rm -f /Library/LaunchDaemons/app.driveway.helper.plist
rm -f /Library/PrivilegedHelperTools/app.driveway.helper
rm -rf /Library/Logs/Driveway

# Hand the app bundle back to the logged-in user.
if [[ -d "${APP}" && "${CONSOLE_UID}" -ne 0 ]]; then
    chown -R "${CONSOLE_UID}:staff" "${APP}"
fi
echo "Driveway helper uninstalled."

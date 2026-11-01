#!/bin/bash
# Removes the Driveway privileged helper and agent. Run as root:
#   uninstall-helper.sh [/Applications/Driveway.app]
# Settings in /Library/Application Support/Driveway are deliberately NOT deleted,
# so a reinstall keeps the owner's choices. Remove that folder by hand to reset.
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
unset BASH_ENV ENV

EXPECTED_APP="/Applications/Driveway.app"

# Refuses (exit 64) if the app path or its Contents is a symlink, since the final
# step is a root `chown -R`. A missing app is fine (nothing to chown).
check_app_symlinks() {
    local app="$1"
    if [[ -L "${app}" || -L "${app}/Contents" ]]; then
        echo "${app} or its Contents is a symlink; refusing." >&2
        return 64
    fi
}

main() {
    local APP="${1:-${EXPECTED_APP}}"

    if [[ "${EUID}" -ne 0 ]]; then
        echo "uninstall-helper.sh must run as root." >&2
        exit 77
    fi
    if [[ "${APP}" != "${EXPECTED_APP}" ]]; then
        echo "Usage: uninstall-helper.sh [${EXPECTED_APP}]" >&2
        exit 64
    fi
    check_app_symlinks "${APP}" || exit 64

    local CONSOLE_UID
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
    if [[ -d "${APP}" && ! -L "${APP}" && "${CONSOLE_UID}" -ne 0 ]]; then
        chown -R "${CONSOLE_UID}:staff" "${APP}"
    fi
    echo "Driveway helper uninstalled."
}

# Allow tests to `source` this file without running main.
if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then
    main "$@"
fi

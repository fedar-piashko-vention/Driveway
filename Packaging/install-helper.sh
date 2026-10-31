#!/bin/bash
# Installs the Driveway privileged helper. Run as root, normally through the
# app's administrator prompt: install-helper.sh /Applications/Driveway.app
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
unset BASH_ENV ENV

EXPECTED_APP="/Applications/Driveway.app"

# Refuses (exit 64) unless the app and every path we read from it are real
# directories/files, not symlinks. Without this, `install` would read through a
# symlink while `chown -R` would not follow it.
check_app_paths() {
    local app="$1" d
    if [[ ! -d "${app}" || -L "${app}" ]]; then
        echo "${app} is missing or a symlink." >&2
        return 64
    fi
    for d in "${app}/Contents" "${app}/Contents/Library" \
             "${app}/Contents/Library/LaunchServices" "${app}/Contents/Resources"; do
        if [[ ! -d "${d}" || -L "${d}" ]]; then
            echo "${d} is missing or a symlink." >&2
            return 64
        fi
    done
    for d in "${app}/Contents/Library/LaunchServices/app.driveway.helper" \
             "${app}/Contents/Resources/app.driveway.helper.plist" \
             "${app}/Contents/Resources/app.driveway.agent.plist"; do
        if [[ ! -f "${d}" || -L "${d}" ]]; then
            echo "${d} is missing or a symlink." >&2
            return 64
        fi
    done
}

main() {
    local APP="${1:-}"

    if [[ "${EUID}" -ne 0 ]]; then
        echo "install-helper.sh must run as root." >&2
        exit 77
    fi
    if [[ "${APP}" != "${EXPECTED_APP}" ]]; then
        echo "Usage: install-helper.sh ${EXPECTED_APP}" >&2
        exit 64
    fi
    check_app_paths "${APP}" || exit 64

    local HELPER_SRC="${APP}/Contents/Library/LaunchServices/app.driveway.helper"
    local RES="${APP}/Contents/Resources"
    local HELPER_DST="/Library/PrivilegedHelperTools/app.driveway.helper"
    local DAEMON_PLIST="/Library/LaunchDaemons/app.driveway.helper.plist"
    local AGENT_PLIST="/Library/LaunchAgents/app.driveway.agent.plist"
    local LOG_DIR="/Library/Logs/Driveway"

    # The helper only trusts callers from a root-owned, non-group/other-writable bundle.
    # ACLs could still grant others write access, so they are stripped too (BSD chmod -N; with -R,
    # symlinks inside the bundle are not followed).
    chown -R root:wheel "${APP}"
    chmod -R -N "${APP}"
    chmod -R go-w "${APP}"
    if [[ "$(stat -f %u "${HELPER_SRC}")" != "0" ]]; then
        echo "${HELPER_SRC} is not root-owned after chown; aborting." >&2
        exit 1
    fi

    # Stop the running jobs before replacing their files.
    local CONSOLE_UID
    CONSOLE_UID="$(stat -f %u /dev/console)"
    launchctl bootout system/app.driveway.helper 2>/dev/null || true
    if [[ "${CONSOLE_UID}" -ne 0 ]]; then
        launchctl bootout "gui/${CONSOLE_UID}/app.driveway.agent" 2>/dev/null || true
    fi

    install -d -o root -g wheel -m 755 /Library/PrivilegedHelperTools
    install -d -o root -g wheel -m 755 "${LOG_DIR}"
    install -S -o root -g wheel -m 755 "${HELPER_SRC}" "${HELPER_DST}"
    install -S -o root -g wheel -m 644 "${RES}/app.driveway.helper.plist" "${DAEMON_PLIST}"
    install -S -o root -g wheel -m 644 "${RES}/app.driveway.agent.plist" "${AGENT_PLIST}"

    # bootout is asynchronous; bootstrap can fail briefly while the old job unloads.
    local ok=0 i
    for i in 1 2 3 4 5; do
        if launchctl bootstrap system "${DAEMON_PLIST}"; then
            ok=1
            break
        fi
        sleep 1
    done
    if [[ "${ok}" -ne 1 ]]; then
        echo "launchctl bootstrap system failed after 5 attempts." >&2
        exit 1
    fi

    if [[ "${CONSOLE_UID}" -ne 0 ]]; then
        launchctl bootstrap "gui/${CONSOLE_UID}" "${AGENT_PLIST}" || true
    fi
    echo "Driveway helper installed."
}

# Allow tests to `source` this file for check_app_paths without running main.
if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then
    main "$@"
fi

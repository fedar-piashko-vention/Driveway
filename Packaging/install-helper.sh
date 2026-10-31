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
             "${app}/Contents/Library/LaunchServices" "${app}/Contents/Resources" \
             "${app}/Contents/Library/LaunchServices/app.driveway.helper.app" \
             "${app}/Contents/Library/LaunchServices/app.driveway.helper.app/Contents" \
             "${app}/Contents/Library/LaunchServices/app.driveway.helper.app/Contents/MacOS" \
             "${app}/Contents/Library/Filesystems" \
             "${app}/Contents/Library/Filesystems/driveway_ext.fs" \
             "${app}/Contents/Library/Filesystems/driveway_ext.fs/Contents" \
             "${app}/Contents/Library/Filesystems/driveway_ext.fs/Contents/Resources"; do
        if [[ ! -d "${d}" || -L "${d}" ]]; then
            echo "${d} is missing or a symlink." >&2
            return 64
        fi
    done
    for d in "${app}/Contents/Library/LaunchServices/app.driveway.helper.app/Contents/MacOS/app.driveway.helper" \
             "${app}/Contents/Resources/app.driveway.helper.plist" \
             "${app}/Contents/Resources/app.driveway.agent.plist" \
             "${app}/Contents/Library/Filesystems/driveway_ext.fs/Contents/Info.plist" \
             "${app}/Contents/Library/Filesystems/driveway_ext.fs/Contents/Resources/driveway_ext.util"; do
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

    local HELPER_SRC="${APP}/Contents/Library/LaunchServices/app.driveway.helper.app"
    local RES="${APP}/Contents/Resources"
    # A small app bundle, so Login Items shows "Driveway" with its icon. It stays out of /Applications: there an
    # admin could swap it without a password, and launchd runs it as root.
    local HELPER_DST="/Library/PrivilegedHelperTools/app.driveway.helper.app"
    local OLD_HELPER="/Library/PrivilegedHelperTools/app.driveway.helper"
    local DAEMON_PLIST="/Library/LaunchDaemons/app.driveway.helper.plist"
    local AGENT_PLIST="/Library/LaunchAgents/app.driveway.agent.plist"
    local LOG_DIR="/Library/Logs/Driveway"
    # Probe-only: lets macOS recognise ext partitions, so it ties Driveway's ext mounts to their disks and
    # Finder's sidebar lists them. diskarbitrationd runs its probe as root, so it is root-owned like the helper.
    local EXT_FS_SRC="${APP}/Contents/Library/Filesystems/driveway_ext.fs"
    local EXT_FS_DST="/Library/Filesystems/driveway_ext.fs"

    # The helper only trusts callers from a root-owned, non-group/other-writable bundle.
    # ACLs could still grant others write access, so they are stripped too. `chmod -R -N` would follow
    # symlinks out of the bundle (and stop at a dangling one), so only non-symlinks are touched.
    chown -R root:wheel "${APP}"
    find "${APP}" ! -type l -exec chmod -N {} +
    chmod -R go-w "${APP}"
    if [[ "$(stat -f %u "${HELPER_SRC}/Contents/MacOS/app.driveway.helper")" != "0" ]]; then
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
    rm -rf "${HELPER_DST}.new" "${HELPER_DST}" "${OLD_HELPER}"
    ditto "${HELPER_SRC}" "${HELPER_DST}.new"
    chown -R root:wheel "${HELPER_DST}.new"
    chmod -R go-w "${HELPER_DST}.new"
    mv "${HELPER_DST}.new" "${HELPER_DST}"
    # Staged as driveway_ext.fs.new, which diskarbitrationd ignores (no .fs suffix), then moved into place.
    install -d -o root -g wheel -m 755 /Library/Filesystems
    rm -rf "${EXT_FS_DST}.new"
    ditto "${EXT_FS_SRC}" "${EXT_FS_DST}.new"
    chown -R root:wheel "${EXT_FS_DST}.new"
    chmod -R go-w "${EXT_FS_DST}.new"
    rm -rf "${EXT_FS_DST}"
    mv "${EXT_FS_DST}.new" "${EXT_FS_DST}"
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

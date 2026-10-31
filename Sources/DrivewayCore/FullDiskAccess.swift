import Foundation

/// macOS privacy protection lets a process open an external drive's raw device (`/dev/disk8s1`) only with Full Disk
/// Access, even as root: without it `open` fails with EPERM. Disk images aren't covered. Driveway's helper needs it
/// for everything that touches a drive: ntfs-3g, ext4fuse, ntfsfix, ntfsclone, e2fsck, mkntfs and mkfs.ext4.
public enum FullDiskAccess {
    /// Where the helper is installed; the path the user adds in System Settings.
    public static let helperAppPath = "/Library/PrivilegedHelperTools/app.driveway.helper.app"
    /// System Settings → Privacy & Security → Full Disk Access.
    public static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
    /// Readable only with Full Disk Access: the standard probe, which needs no drive.
    public static let probePath = "/Library/Application Support/com.apple.TCC/TCC.db"

    /// What opening `probePath` read-only says: 0 (it opened) is granted, EPERM or EACCES is denied, and anything
    /// else (the file is missing, say) tells nothing.
    public static func status(openErrno: Int32) -> Bool? {
        switch openErrno {
        case 0: true
        case EPERM, EACCES: false
        default: nil
        }
    }

    /// True when a tool's output says it was refused a drive: "Operation not permitted" on a line about opening a
    /// device (ntfs-3g, ntfsfix, ntfsclone: `'/dev/disk8s1'`), e2fsprogs' "while trying to ..." or umount's
    /// `unmount(<path>)`.
    public static func deniedInToolOutput(_ output: String) -> Bool {
        output.split(whereSeparator: \.isNewline).contains { line in
            line.range(of: "Operation not permitted", options: .caseInsensitive) != nil
                && (line.contains("/dev/") || line.contains("while trying to") || line.contains("unmount("))
        }
    }
}

extension Copy {
    /// Why a drive stays read-only, or an operation failed, when the helper has no Full Disk Access.
    /// No drive name in it: the notification already says "Driveway couldn't mount <label>:", and the Info tab shows
    /// it under the drive.
    public static let needsFullDiskAccess = "Driveway's helper needs Full Disk Access. Open Setup to allow it."

    /// The line above the helper's path in the Setup row.
    public static let fullDiskAccessHint =
        "In Full Disk Access, click +, press ⌘⇧G, enter this path and turn the helper on. It lets Driveway's helper read and write external drives, the way Tuxera's driver can."

    /// What to do in System Settings. Granting an app access is not a security setting: nothing is turned off.
    public static let fullDiskAccessSteps =
        "In System Settings → Privacy & Security → Full Disk Access, click +, press ⌘⇧G, enter \(FullDiskAccess.helperAppPath), click Open and turn it on. This lets Driveway's helper read and write external drives, the way Tuxera's driver can. Driveway checks again when you come back."
}

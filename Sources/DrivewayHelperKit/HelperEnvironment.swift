import DrivewayCore
import DrivewayIPC
import Foundation
import SystemConfiguration

/// What the helper reads from the system at startup and when it refreshes its feature states.
public enum HelperEnvironment {
    public static let macFUSEInfoPlist = URL(fileURLWithPath: "/Library/Filesystems/macfuse.fs/Contents/Info.plist")
    public static let filesystemsDirectory = URL(fileURLWithPath: "/Library/Filesystems")

    /// The OS build (`sysctl kern.osversion`, e.g. "24G84"); "unknown" if it can't be read.
    public static func osBuild() -> String {
        var size = 0
        guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname("kern.osversion", &buffer, &size, nil, 0) == 0 else { return "unknown" }
        let build = String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        return build.isEmpty ? "unknown" : build
    }

    /// Whether this process has Full Disk Access: opens `probePath` read-only and closes it at once. Without Full
    /// Disk Access the open fails with EPERM, even as root. Nil when the result tells nothing (no such file).
    public static func fullDiskAccess(probePath: String = FullDiskAccess.probePath) -> Bool? {
        let fd = open(probePath, O_RDONLY)
        if fd >= 0 {
            close(fd)
            return FullDiskAccess.status(openErrno: 0)
        }
        return FullDiskAccess.status(openErrno: errno)
    }

    /// The user at the console, from `SCDynamicStoreCopyConsoleUser`.
    public static func consoleUser() -> ConsoleUser? {
        var uid: uid_t = 0
        var gid: gid_t = 0
        let name = SCDynamicStoreCopyConsoleUser(nil, &uid, &gid) as String?
        return consoleUser(name: name, uid: uid, gid: gid)
    }

    /// Nobody is logged in when there is no console user, or it's the login window (uid 0).
    public static func consoleUser(name: String?, uid: UInt32, gid: UInt32) -> ConsoleUser? {
        guard let name, !name.isEmpty, name != "loginwindow", uid != 0 else { return nil }
        return ConsoleUser(uid: uid, gid: gid)
    }

    /// `CFBundleVersion` of macFUSE's Info.plist.
    public static func macFUSEVersion(infoPlist data: Data?) -> SemanticVersion? {
        guard let data,
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let version = plist["CFBundleVersion"] as? String
        else { return nil }
        return SemanticVersion(version.trimmingCharacters(in: .whitespaces))
    }

    /// The helper's view of the installed tools, with the same rules as the app's scan (`ToolInventoryScanner`):
    /// NTFS needs ntfs-3g and ntfsfix, e2fsprogs needs e2fsck and mkfs.ext4. It is current with itself, so
    /// helper and app versions are both `helperProtocolVersion`.
    public static func toolInventory(
        paths: ToolPaths, backend: BackendAvailability, fileExists: (String) -> Bool, macFUSEInfoPlist: Data?,
        filesystemBundles: [String]
    ) -> ToolInventory {
        ToolInventory(
            hasHomebrew: fileExists(paths.brew),
            macFUSEVersion: macFUSEVersion(infoPlist: macFUSEInfoPlist),
            backend: backend,
            hasNTFS3G: fileExists(paths.ntfs3g) && fileExists(paths.ntfsfix),
            hasExt4fuse: fileExists(paths.ext4fuse),
            hasE2fsprogs: fileExists(paths.e2fsck) && fileExists(paths.mkfsExt4),
            helperVersion: helperProtocolVersion,
            appVersion: helperProtocolVersion,
            conflictingDrivers: ConflictingDrivers.detect(filesystemBundles: filesystemBundles))
    }

    /// `toolInventory` from the real file system.
    public static func currentToolInventory(paths: ToolPaths, backend: BackendAvailability) -> ToolInventory {
        let fm = FileManager.default
        return toolInventory(
            paths: paths, backend: backend, fileExists: { fm.isExecutableFile(atPath: $0) },
            macFUSEInfoPlist: try? Data(contentsOf: macFUSEInfoPlist),
            filesystemBundles: (try? fm.contentsOfDirectory(atPath: filesystemsDirectory.path)) ?? [])
    }
}

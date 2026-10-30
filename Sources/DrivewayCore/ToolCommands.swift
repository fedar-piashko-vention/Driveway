import Foundation

public enum CheckMode: String, Codable, Sendable {
    case check, repair, repairForce
}

/// The only place external tool command lines are defined. The root helper runs these.
public enum ToolCommands {
    /// ntfs-3g mount. Options: `[backend=fskit,]volname=<label>,uid=<uid>,gid=<gid>[,ro]`.
    public static func ntfs3gMount(
        device: String, mountPoint: String, volumeName: String, readOnly: Bool,
        uid: UInt32, gid: UInt32, backend: MountBackend, paths: ToolPaths
    ) -> Command {
        var options = "volname=\(MountNaming.fuseOptionEscaped(volumeName)),uid=\(uid),gid=\(gid)"
        if readOnly { options += ",ro" }
        return Command(
            executable: paths.ntfs3g,
            arguments: [device, mountPoint, "-o", backendPrefix(backend) + options])
    }

    /// ext4fuse mount (read-only by nature; needs no uid/gid). Options: `[backend=fskit,]volname=<label>`.
    public static func ext4fuseMount(
        device: String, mountPoint: String, volumeName: String, backend: MountBackend, paths: ToolPaths
    ) -> Command {
        let options = "volname=\(MountNaming.fuseOptionEscaped(volumeName))"
        return Command(
            executable: paths.ext4fuse,
            arguments: [device, mountPoint, "-o", backendPrefix(backend) + options])
    }

    /// `.check` is `-n` (no changes); `.repair` is `-d` (clear the dirty flag, fix what is safe).
    /// ntfsfix is check/repair only, so `.repairForce` behaves like `.repair`.
    public static func ntfsfix(device: String, mode: CheckMode, paths: ToolPaths) -> Command {
        let flag = mode == .check ? "-n" : "-d"
        return Command(executable: paths.ntfsfix, arguments: [flag, device])
    }

    /// Saves a metadata-only image of an NTFS volume (a safety backup before a repair).
    public static func ntfsclone(device: String, imagePath: String, paths: ToolPaths) -> Command {
        Command(executable: paths.ntfsclone, arguments: ["--save-image", "--output", imagePath, device])
    }

    /// `.check` is `-n -f`, `.repair` is `-p -f`, `.repairForce` is `-y -f`.
    public static func e2fsck(device: String, mode: CheckMode, paths: ToolPaths) -> Command {
        let flag: String
        switch mode {
        case .check: flag = "-n"
        case .repair: flag = "-p"
        case .repairForce: flag = "-y"
        }
        return Command(executable: paths.e2fsck, arguments: [flag, "-f", device])
    }

    public static func diskutil(_ args: String..., paths: ToolPaths) -> Command {
        Command(executable: paths.diskutil, arguments: args)
    }

    /// Unmounts through diskutil: a mount started by the root helper cannot be unmounted
    /// by the user with `umount`.
    public static func unmount(device: String, paths: ToolPaths) -> Command {
        Command(executable: paths.diskutil, arguments: ["unmount", device])
    }

    private static func backendPrefix(_ backend: MountBackend) -> String {
        backend == .fskit ? "backend=fskit," : ""
    }
}

public enum MountNaming {
    /// `/Volumes/<label>`, made unique against `existing` by appending " 1", " 2", and so on.
    /// "/" in the label becomes ":" (Finder's POSIX mapping); an empty or whitespace-only
    /// label becomes "Untitled". Non-ASCII is kept as is.
    public static func mountPoint(for label: String, existing: Set<String>) -> String {
        var name = label.replacingOccurrences(of: "/", with: ":")
        if name.allSatisfy(\.isWhitespace) { name = "Untitled" }
        let base = "/Volumes/\(name)"
        var candidate = base
        var n = 0
        while existing.contains(candidate) {
            n += 1
            candidate = "\(base) \(n)"
        }
        return candidate
    }

    /// Backslash-escapes `\` and `,` for use inside a comma-separated `-o` option value.
    public static func fuseOptionEscaped(_ s: String) -> String {
        var out = ""
        for ch in s {
            if ch == "\\" || ch == "," { out.append("\\") }
            out.append(ch)
        }
        return out
    }
}

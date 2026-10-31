import Foundation

public enum CheckMode: String, Codable, Sendable {
    case check, repair, repairForce
}

/// The only place external tool command lines are defined. The root helper runs these.
public enum ToolCommands {
    /// ntfs-3g mount. Options: `[backend=fskit,]volname=<label>,uid=<uid>,gid=<gid>,norecover[,ro]`.
    ///
    /// `norecover` because ntfs-3g's default, `recover`, clears the Windows logfile of a drive that wasn't
    /// unmounted properly and mounts it read/write: a silent fix. With `norecover` such a drive is refused,
    /// and Driveway falls back to a read-only mount with Fix & mount on offer.
    public static func ntfs3gMount(
        device: String, mountPoint: String, volumeName: String, readOnly: Bool,
        uid: UInt32, gid: UInt32, backend: MountBackend, paths: ToolPaths
    ) -> Command {
        var options = "volname=\(MountNaming.fuseOptionEscaped(volumeName)),uid=\(uid),gid=\(gid),norecover"
        if readOnly { options += ",ro" }
        return Command(
            executable: paths.ntfs3g,
            arguments: [device, mountPoint, "-o", backendPrefix(backend) + options])
    }

    /// ext4fuse mount (read-only by nature; needs no uid/gid).
    /// Options: `[backend=fskit,]volname=<label>,allow_other,fsname=<device>`. ntfs-3g adds `allow_other` and
    /// `fsname` itself; ext4fuse doesn't, and without `allow_other` a mount made by root is closed to the user.
    public static func ext4fuseMount(
        device: String, mountPoint: String, volumeName: String, backend: MountBackend, paths: ToolPaths
    ) -> Command {
        let options = "volname=\(MountNaming.fuseOptionEscaped(volumeName)),allow_other,fsname=\(MountNaming.fuseOptionEscaped(device))"
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

    /// Saves an image of an NTFS volume in ntfsclone's special format: every cluster in use (all files and
    /// metadata, not only metadata), so it takes as long as copying the used data. A safety backup before a
    /// repair. `--force` because the drives that need "Back up first" are the ones with the dirty flag set.
    public static func ntfsclone(device: String, imagePath: String, paths: ToolPaths) -> Command {
        Command(executable: paths.ntfsclone, arguments: ["--save-image", "--force", "--output", imagePath, device])
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

    /// Quick NTFS format: `mkntfs --quick --label <label> <device>`.
    public static func mkntfs(device: String, label: String, paths: ToolPaths) -> Command {
        Command(executable: paths.mkntfs, arguments: ["--quick", "--label", label, device])
    }

    /// ext4 format: `mkfs.ext4 -F -L <label> <device>` (`-F` because the device is a whole partition
    /// that may carry an older signature).
    public static func mkfsExt4(device: String, label: String, paths: ToolPaths) -> Command {
        Command(executable: paths.mkfsExt4, arguments: ["-F", "-L", label, device])
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
    /// Longest file name component, in UTF-8 bytes (NAME_MAX).
    static let maxNameBytes = 255
    /// Bytes kept free for a collision suffix such as " 12".
    static let suffixReserveBytes = 8

    /// `/Volumes/<label>`, made unique against `existing` by appending " 1", " 2", and so on.
    /// `existing` holds full mount-point paths (for example "/Volumes/BACKUP"); it is compared
    /// case-insensitively because /Volumes is on case-insensitive APFS.
    ///
    /// The label is sanitised because the mount runs as root and anyone can set a label:
    /// "/" becomes ":" (Finder's POSIX mapping), control characters (category Cc, including
    /// NUL and newlines) are removed, surrounding whitespace is trimmed, and the result is
    /// cut to fit NAME_MAX on a Character boundary, leaving room for a collision suffix.
    /// An empty result, "." or ".." becomes "Untitled". Non-ASCII is kept as is.
    public static func mountPoint(for label: String, existing: Set<String>) -> String {
        let name = sanitizedName(label)
        let taken = Set(existing.map { $0.lowercased() })
        let base = "/Volumes/\(name)"
        var candidate = base
        var n = 0
        while taken.contains(candidate.lowercased()) {
            n += 1
            candidate = "\(base) \(n)"
        }
        return candidate
    }

    static func sanitizedName(_ label: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in label.unicodeScalars {
            if scalar == "/" {
                scalars.append(":")
            } else if scalar.properties.generalCategory != .control {
                scalars.append(scalar)
            }
        }
        var name = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        let budget = maxNameBytes - suffixReserveBytes
        if name.utf8.count > budget {
            var cut = ""
            var bytes = 0
            for ch in name {
                let size = String(ch).utf8.count
                if bytes + size > budget { break }
                cut.append(ch)
                bytes += size
            }
            name = cut.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if name.isEmpty || name == "." || name == ".." { return "Untitled" }
        return name
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

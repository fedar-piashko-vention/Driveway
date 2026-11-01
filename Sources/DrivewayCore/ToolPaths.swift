/// One external command line: an absolute executable path and its argument vector.
public struct Command: Codable, Equatable, Sendable {
    public var executable: String
    public var arguments: [String]

    public init(executable: String, arguments: [String]) {
        self.executable = executable
        self.arguments = arguments
    }
}

/// Absolute paths of the external tools Driveway runs. Paths were verified by the spike
/// (see docs/spike-results.md, "Tool paths").
public struct ToolPaths: Sendable {
    public var brewPrefix: String

    public init(brewPrefix: String = "/opt/homebrew") {
        self.brewPrefix = brewPrefix
    }

    public var brew: String { "\(brewPrefix)/bin/brew" }
    public var ntfs3g: String { "\(brewPrefix)/bin/ntfs-3g" }
    public var ntfsfix: String { "\(brewPrefix)/bin/ntfsfix" }
    public var ntfsinfo: String { "\(brewPrefix)/bin/ntfsinfo" }
    public var mkntfs: String { "\(brewPrefix)/sbin/mkntfs" }
    public var ntfsclone: String { "\(brewPrefix)/sbin/ntfsclone" }
    public var ext4fuse: String { "\(brewPrefix)/bin/ext4fuse" }
    /// e2fsprogs is keg-only, so its tools live under `opt/e2fsprogs`.
    public var e2fsck: String { "\(brewPrefix)/opt/e2fsprogs/sbin/e2fsck" }
    public var mkfsExt4: String { "\(brewPrefix)/opt/e2fsprogs/sbin/mkfs.ext4" }
    public var diskutil: String { "/usr/sbin/diskutil" }
    public var umount: String { "/sbin/umount" }
}

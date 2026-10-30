import Foundation

public enum PartitionScheme: String, Codable, Sendable {
    case gpt = "GPT"
    case mbr = "MBR"
}

public enum FormatTarget: Codable, Equatable, Sendable {
    /// Erase the whole disk and create a new partition table. The associated value is a BSD name such as "disk4".
    case wholeDisk(String)
    /// Re-format one partition in place. The associated value is a BSD name such as "disk4s2".
    case partition(String)
}

public struct FormatRequest: Codable, Equatable, Sendable {
    public var filesystem: FilesystemKind
    public var label: String
    public var scheme: PartitionScheme
    public var target: FormatTarget
    /// What the user typed to confirm; must equal the current drive name.
    public var confirmation: String

    public init(
        filesystem: FilesystemKind, label: String, scheme: PartitionScheme, target: FormatTarget,
        confirmation: String
    ) {
        self.filesystem = filesystem
        self.label = label
        self.scheme = scheme
        self.target = target
        self.confirmation = confirmation
    }
}

public enum FormatValidationError: Error, Codable, Equatable, Sendable {
    case unsupportedFilesystem
    case emptyLabel
    case labelTooLong(max: Int)
    case invalidCharacters
    case confirmationMismatch
}

/// Checks a format request, in this order: filesystem, empty label (after trimming whitespace),
/// label length, label characters, confirmation. The label is checked exactly as it will be passed to
/// the tools. The confirmation is compared after trimming whitespace only, and case-sensitively.
public func validate(_ r: FormatRequest, currentDriveName: String) throws(FormatValidationError) {
    guard Formatting.supported.contains(r.filesystem) else { throw .unsupportedFilesystem }
    if r.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw .emptyLabel }

    switch r.filesystem {
    case .ntfs:
        // NTFS and exFAT labels are measured in UTF-16 code units.
        if r.label.utf16.count > 32 { throw .labelTooLong(max: 32) }
        if r.label.unicodeScalars.contains(where: Formatting.isReservedInWindowsLabel) {
            throw .invalidCharacters
        }
    case .exfat:
        if r.label.utf16.count > 11 { throw .labelTooLong(max: 11) }
        if r.label.unicodeScalars.contains(where: Formatting.isReservedInWindowsLabel) {
            throw .invalidCharacters
        }
    case .ext4:
        if r.label.utf8.count > 16 { throw .labelTooLong(max: 16) }
        if r.label.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) {
            throw .invalidCharacters
        }
    case .fat32:
        if r.label.utf8.count > 11 { throw .labelTooLong(max: 11) }
        if !r.label.unicodeScalars.allSatisfy(Formatting.fat32Allowed.contains) { throw .invalidCharacters }
    default:
        throw .unsupportedFilesystem
    }

    let typed = r.confirmation.trimmingCharacters(in: .whitespacesAndNewlines)
    let expected = currentDriveName.trimmingCharacters(in: .whitespacesAndNewlines)
    if typed != expected { throw .confirmationMismatch }
}

/// "All 620 GB on BACKUP will be erased". Sizes use decimal (file) units, like Finder.
public func eraseWarning(label: String, capacityBytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    let size = formatter.string(fromByteCount: capacityBytes)
        .replacingOccurrences(of: "\u{00A0}", with: " ")
    return "All \(size) on \(label) will be erased"
}

enum Formatting {
    static let supported: Set<FilesystemKind> = [.ntfs, .ext4, .exfat, .fat32]
    static let placeholderLabel = "DRIVEWAYTMP"
    static let efiGUID = "C12A7328-F81F-11D2-BA4B-00A0C93EC93B"

    /// FAT32 volume label characters: A-Z a-z 0-9 space _ - ! # $ % & ' ( ) @ ^ { } ~
    static let fat32Allowed: Set<Unicode.Scalar> = {
        var set = Set<Unicode.Scalar>()
        for range in [("A" as Unicode.Scalar)..."Z", "a"..."z", "0"..."9"] {
            for v in range.lowerBound.value...range.upperBound.value {
                if let s = Unicode.Scalar(v) { set.insert(s) }
            }
        }
        for s in " _-!#$%&'()@^{}~".unicodeScalars { set.insert(s) }
        return set
    }()

    /// Control characters and the characters Windows reserves in names: " * / : < > ? \ |
    static func isReservedInWindowsLabel(_ s: Unicode.Scalar) -> Bool {
        s.properties.generalCategory == .control || "\"*/:<>?\\|".unicodeScalars.contains(s)
    }
}

public enum FormatPlanner {
    /// The commands that run first. Whole disk: one `diskutil eraseDisk` (NTFS and ext4 first erase to a
    /// temporary ExFAT volume, which gives the partition type Windows expects for NTFS: Microsoft Basic Data
    /// on GPT, type 0x07 on MBR). Partition: `eraseVolume` for exFAT and FAT32, or an unmount for NTFS and ext4.
    public static func eraseCommands(_ r: FormatRequest, paths: ToolPaths) -> [Command] {
        switch r.target {
        case .wholeDisk(let disk):
            let (name, label): (String, String) =
                switch r.filesystem {
                case .exfat: ("ExFAT", r.label)
                case .fat32: ("MS-DOS FAT32", r.label)
                default: ("ExFAT", Formatting.placeholderLabel)
                }
            return [
                ToolCommands.diskutil(
                    "eraseDisk", name, label, r.scheme.rawValue, "/dev/\(disk)", paths: paths)
            ]
        case .partition(let partition):
            let device = "/dev/\(partition)"
            switch r.filesystem {
            case .exfat:
                return [ToolCommands.diskutil("eraseVolume", "ExFAT", r.label, device, paths: paths)]
            case .fat32:
                return [ToolCommands.diskutil("eraseVolume", "MS-DOS FAT32", r.label, device, paths: paths)]
            default:
                return [ToolCommands.unmount(device: device, paths: paths)]
            }
        }
    }

    /// The commands that run after `eraseCommands`, on the data partition. Empty for exFAT and FAT32.
    /// For a partition target, pass that partition's BSD name as `dataPartition`.
    public static func finishCommands(
        _ r: FormatRequest, dataPartition: String, paths: ToolPaths
    ) -> [Command] {
        let device = "/dev/\(dataPartition)"
        switch r.filesystem {
        case .ntfs:
            return finish(.ntfs, device, r, paths, unmountFirst: wholeDisk(r))
        case .ext4:
            return finish(.ext4, device, r, paths, unmountFirst: wholeDisk(r))
        default:
            return []
        }
    }

    /// The BSD name of the partition that holds the data after a whole-disk erase: the largest partition
    /// of `wholeDisk` that is not the whole disk itself and not the EFI system partition.
    public static func dataPartition(of wholeDisk: String, in disks: [DiskDescription]) -> String? {
        disks
            .filter { $0.wholeDisk == wholeDisk && !$0.isWholeMedia && !isEFI($0.contentType) }
            .max { $0.sizeBytes < $1.sizeBytes }?
            .bsdName
    }

    private static func isEFI(_ contentType: String?) -> Bool {
        guard let c = contentType else { return false }
        return c == "EFI" || c.uppercased() == Formatting.efiGUID
    }

    private static func wholeDisk(_ r: FormatRequest) -> Bool {
        if case .wholeDisk = r.target { return true }
        return false
    }

    /// After a whole-disk erase the new ExFAT volume is mounted, so it is unmounted first. A partition
    /// target was already unmounted by `eraseCommands`.
    private static func finish(
        _ fs: FilesystemKind, _ device: String, _ r: FormatRequest, _ paths: ToolPaths, unmountFirst: Bool
    ) -> [Command] {
        var out: [Command] = []
        if unmountFirst { out.append(ToolCommands.unmount(device: device, paths: paths)) }
        out.append(
            fs == .ntfs
                ? ToolCommands.mkntfs(device: device, label: r.label, paths: paths)
                : ToolCommands.mkfsExt4(device: device, label: r.label, paths: paths))
        return out
    }
}

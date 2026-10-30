import Foundation

public enum FilesystemProbe {
    private static let extMagicOffset = 1080
    private static let extCompatOffset = 1116
    private static let extIncompatOffset = 1120
    private static let extHeaderLength = 1124

    /// Identifies NTFS or ext2/3/4 from the first bytes of a volume. Returns nil if neither matches.
    public static func detect(header: Data) -> FilesystemKind? {
        let bytes = [UInt8](header)
        if bytes.count >= 11, Array(bytes[3..<11]) == Array("NTFS    ".utf8) { return .ntfs }
        guard bytes.count >= extHeaderLength else { return nil }
        guard bytes[extMagicOffset] == 0x53, bytes[extMagicOffset + 1] == 0xEF else { return nil }
        let compat = littleEndianUInt32(bytes, at: extCompatOffset)
        let incompat = littleEndianUInt32(bytes, at: extIncompatOffset)
        // incompat: 0x40 extents, 0x80 64bit, 0x200 flex_bg. compat: 0x4 has_journal.
        if incompat & (0x40 | 0x80 | 0x200) != 0 { return .ext4 }
        if compat & 0x4 != 0 { return .ext3 }
        return .ext2
    }

    /// Maps DiskArbitration's volume kind/type to a filesystem. Nil kind means unknown.
    public static func kind(forDAVolumeKind kind: String?, volumeType: String?) -> FilesystemKind? {
        guard let kind else { return nil }
        switch kind.lowercased() {
        case "ntfs": return .ntfs
        case "exfat": return .exfat
        case "msdos":
            let type = volumeType?.uppercased() ?? ""
            if type.contains("FAT32") { return .fat32 }
            if type.contains("FAT16") { return .fat16 }
            return .other
        default: return .other
        }
    }

    private static func littleEndianUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[offset + $1]) << (8 * UInt32($1)) }
    }
}

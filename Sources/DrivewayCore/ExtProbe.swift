import Foundation

/// What Driveway's ext probe (`driveway_ext.util` in `/Library/Filesystems/driveway_ext.fs`) reads and reports.
/// The probe only names ext partitions so DiskArbitration knows them: then it ties Driveway's ext4fuse mount to
/// the disk and Finder lists the volume. The probe never mounts anything; the helper does.
public enum ExtProbe {
    /// DiskArbitration's volume kind for a partition the probe recognised: the bundle's CFBundleName.
    /// macOS has no ext driver, so only Driveway can mount a volume of this kind.
    public static let volumeKind = "driveway_ext"

    /// Bytes the probe reads from the start of the volume. The superblock is bytes 1024–2047; raw devices
    /// only read whole sectors, and 4096 is a multiple of every sector size.
    public static let headerLength = 4096

    private static let superblock = 1024
    private static let inodesCountOffset = superblock + 0
    private static let logBlockSizeOffset = superblock + 24
    private static let revisionOffset = superblock + 76
    private static let uuidOffset = superblock + 104
    private static let labelOffset = superblock + 120
    private static let labelLength = 16

    /// `/dev/r<name>` for a BSD name such as `disk6s1` (DiskArbitration passes the bare name); nil for anything else.
    public static func rawDevicePath(forBSDName name: String) -> String? {
        guard name.wholeMatch(of: /disk[0-9]+(s[0-9]+)*/) != nil else { return nil }
        return "/dev/r" + name
    }

    /// The label and UUID, or nil unless `FilesystemProbe.detect` sees ext and the superblock looks sane.
    /// The extra checks keep a stale superblock left under another filesystem from being named ext.
    public static func superblock(header: Data) -> ExtSuperblock? {
        let bytes = [UInt8](header)
        guard bytes.count >= labelOffset + labelLength,
              let kind = FilesystemProbe.detect(header: header), [.ext2, .ext3, .ext4].contains(kind),
              uint32(bytes, at: inodesCountOffset) > 0,
              uint32(bytes, at: logBlockSizeOffset) <= 6,  // blocks of 1 KiB << 6 = 64 KiB at most
              uint32(bytes, at: revisionOffset) <= 1
        else { return nil }

        let raw = bytes[labelOffset..<labelOffset + labelLength].prefix { $0 != 0 }
        // The label reaches DiskArbitration as a line on stdout: control characters would cut or garble it.
        let label = String(decoding: raw, as: UTF8.self).unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) }
        let uuidBytes = Array(bytes[uuidOffset..<uuidOffset + 16])
        let uuid = uuidBytes.allSatisfy { $0 == 0 } ? nil : UUID(uuid: (
            uuidBytes[0], uuidBytes[1], uuidBytes[2], uuidBytes[3], uuidBytes[4], uuidBytes[5], uuidBytes[6],
            uuidBytes[7], uuidBytes[8], uuidBytes[9], uuidBytes[10], uuidBytes[11], uuidBytes[12], uuidBytes[13],
            uuidBytes[14], uuidBytes[15]))
        return ExtSuperblock(label: String(String.UnicodeScalarView(label)), uuid: uuid)
    }

    private static func uint32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[offset + $1]) << (8 * UInt32($1)) }
    }
}

public struct ExtSuperblock: Equatable, Sendable {
    /// Empty when the volume has no label.
    public var label: String
    /// Nil when the superblock's UUID is all zeros.
    public var uuid: UUID?
}

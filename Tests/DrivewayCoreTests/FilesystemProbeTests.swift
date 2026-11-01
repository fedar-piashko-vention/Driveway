import Testing
import Foundation
@testable import DrivewayCore

struct FilesystemProbeTests {
    func header(_ edits: [(Int, [UInt8])]) -> Data {
        var d = Data(count: 4096)
        for (o, b) in edits { d.replaceSubrange(o..<o + b.count, with: b) }
        return d
    }

    @Test func detectsNTFSByOEMID() {
        #expect(FilesystemProbe.detect(header: header([(3, Array("NTFS    ".utf8))])) == .ntfs)
    }

    @Test func detectsExtVariantsFromSuperblock() {
        let magic = (1080, [UInt8]([0x53, 0xEF]))
        #expect(FilesystemProbe.detect(header: header([magic])) == .ext2)
        #expect(FilesystemProbe.detect(header: header([magic, (1116, [0x04, 0, 0, 0])])) == .ext3)        // has_journal
        #expect(FilesystemProbe.detect(header: header([magic, (1116, [0x04, 0, 0, 0]), (1120, [0x40, 0, 0, 0])])) == .ext4) // extents
    }

    @Test func unknownAndShortHeadersAreNil() {
        #expect(FilesystemProbe.detect(header: Data(count: 4096)) == nil)
        #expect(FilesystemProbe.detect(header: Data(count: 100)) == nil)
    }

    @Test func mapsDAVolumeKinds() {
        #expect(FilesystemProbe.kind(forDAVolumeKind: "ntfs", volumeType: nil) == .ntfs)
        #expect(FilesystemProbe.kind(forDAVolumeKind: "exfat", volumeType: nil) == .exfat)
        #expect(FilesystemProbe.kind(forDAVolumeKind: "msdos", volumeType: "MS-DOS FAT32") == .fat32)
        #expect(FilesystemProbe.kind(forDAVolumeKind: "msdos", volumeType: "MS-DOS FAT16") == .fat16)
        #expect(FilesystemProbe.kind(forDAVolumeKind: "apfs", volumeType: nil) == .other)
        #expect(FilesystemProbe.kind(forDAVolumeKind: nil, volumeType: nil) == nil)
    }
}

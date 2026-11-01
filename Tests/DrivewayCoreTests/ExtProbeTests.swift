import Testing
import Foundation
@testable import DrivewayCore

struct ExtProbeTests {
    /// A 4 KiB volume start holding an ext4 superblock (it starts at byte 1024).
    func header(label: [UInt8] = Array("LINUX".utf8), uuid: [UInt8] = Array(1...16), _ edits: [(Int, [UInt8])] = []) -> Data {
        var b = [UInt8](repeating: 0, count: 4096)
        b[1024] = 0x00; b[1025] = 0x10                  // s_inodes_count 4096
        b[1080] = 0x53; b[1081] = 0xEF                  // magic
        b[1100] = 0x01                                  // s_rev_level: dynamic
        b[1120] = 0x40                                  // incompat: extents
        b.replaceSubrange(1128..<1128 + uuid.count, with: uuid)
        b.replaceSubrange(1144..<1144 + label.count, with: label)
        for (o, bytes) in edits { b.replaceSubrange(o..<o + bytes.count, with: bytes) }
        return Data(b)
    }

    @Test func readsTheLabelAndUUID() {
        let sb = ExtProbe.superblock(header: header())
        #expect(sb?.label == "LINUX")
        #expect(sb?.uuid == UUID(uuidString: "01020304-0506-0708-090A-0B0C0D0E0F10"))
    }

    @Test func aFullSixteenByteLabelHasNoTerminator() {
        #expect(ExtProbe.superblock(header: header(label: Array("ABCDEFGHIJKLMNOP".utf8)))?.label == "ABCDEFGHIJKLMNOP")
    }

    @Test func emptyLabelAndZeroUUIDAreAbsent() {
        let sb = ExtProbe.superblock(header: header(label: [], uuid: [UInt8](repeating: 0, count: 16)))
        #expect(sb?.label == "")
        #expect(sb?.uuid == nil)
    }

    @Test func utf8LabelsDecodeAndControlCharactersAreDropped() {
        // DiskArbitration reads the label from the probe's stdout, so a newline would end it early.
        #expect(ExtProbe.superblock(header: header(label: Array("Фото\nA".utf8)))?.label == "ФотоA")
    }

    @Test func rejectsWhatIsNotASaneExtSuperblock() {
        #expect(ExtProbe.superblock(header: Data(count: 4096)) == nil)                           // no magic
        #expect(ExtProbe.superblock(header: header().prefix(1100)) == nil)                       // short read
        #expect(ExtProbe.superblock(header: header([(1024, [0, 0, 0, 0])])) == nil)              // no inodes
        #expect(ExtProbe.superblock(header: header([(1048, [7, 0, 0, 0])])) == nil)              // 128 KiB blocks
        #expect(ExtProbe.superblock(header: header([(1100, [2, 0, 0, 0])])) == nil)              // unknown revision
        // An NTFS boot sector wins, as in FilesystemProbe.detect: a stale ext superblock under NTFS isn't ext.
        #expect(ExtProbe.superblock(header: header([(3, Array("NTFS    ".utf8))])) == nil)
    }

    @Test func rawDevicePathOnlyForBSDNames() {
        #expect(ExtProbe.rawDevicePath(forBSDName: "disk6s1") == "/dev/rdisk6s1")
        #expect(ExtProbe.rawDevicePath(forBSDName: "disk12s3s1") == "/dev/rdisk12s3s1")
        #expect(ExtProbe.rawDevicePath(forBSDName: "disk6") == "/dev/rdisk6")
        #expect(ExtProbe.rawDevicePath(forBSDName: "/dev/disk6s1") == nil)
        #expect(ExtProbe.rawDevicePath(forBSDName: "disk6s1/../x") == nil)
        #expect(ExtProbe.rawDevicePath(forBSDName: "disks1") == nil)
        #expect(ExtProbe.rawDevicePath(forBSDName: "") == nil)
    }
}

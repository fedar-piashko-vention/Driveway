import Testing
import Foundation
@testable import DrivewayCore

struct ProtectionTests {
    func disk(
        _ bsd: String, whole: String, internal isInternal: Bool = false, image: Bool = false,
        kind: String? = nil, content: String? = nil
    ) -> DiskDescription {
        DiskDescription(
            bsdName: bsd, wholeDisk: whole, isWholeMedia: bsd == whole, isInternal: isInternal,
            isDiskImage: image, volumeKind: kind, volumeType: nil, contentType: content,
            volumeName: nil, volumeUUID: nil, mediaUUID: nil, sizeBytes: 1_000_000,
            deviceModel: "Test", volumePath: nil)
    }

    func plist(_ dict: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
    }

    @Test func bootDiskIsProtected() {
        let policy = ProtectionPolicy(bootWholeDisks: ["disk0"])
        let whole = disk("disk0", whole: "disk0")
        let part = disk("disk0s1", whole: "disk0", kind: "ntfs", content: "Microsoft Basic Data")
        let all = [whole, part]
        #expect(policy.isProtected(part, allDisks: all))
        #expect(policy.isProtected(whole, allDisks: all))
    }

    @Test func anyAPFSOrHFSSiblingProtectsWholeDisk() {
        let policy = ProtectionPolicy()
        let ntfs = disk("disk4s1", whole: "disk4", kind: "ntfs", content: "Microsoft Basic Data")
        let apfs = disk("disk4s2", whole: "disk4", content: "Apple_APFS")
        let whole = disk("disk4", whole: "disk4")
        let all = [whole, ntfs, apfs]
        #expect(policy.isProtected(ntfs, allDisks: all))
        #expect(policy.isProtected(apfs, allDisks: all))
        #expect(policy.isProtected(whole, allDisks: all))
        // Without the APFS sibling the NTFS partition is allowed.
        #expect(!policy.isProtected(ntfs, allDisks: [whole, ntfs]))
    }

    @Test func mixedPartitionDisks() {
        let policy = ProtectionPolicy()
        let d5s1 = disk("disk5s1", whole: "disk5", kind: "ntfs", content: "Microsoft Basic Data")
        let d5s2 = disk("disk5s2", whole: "disk5", kind: "exfat", content: "Microsoft Basic Data")
        let d6s1 = disk("disk6s1", whole: "disk6", kind: "ntfs", content: "Microsoft Basic Data")
        let d6s2 = disk("disk6s2", whole: "disk6", kind: "hfs", content: "Apple_HFS")
        let all = [d5s1, d5s2, d6s1, d6s2]
        #expect(!policy.isProtected(d5s1, allDisks: all))
        #expect(!policy.isProtected(d5s2, allDisks: all))
        #expect(policy.isProtected(d6s1, allDisks: all))
        #expect(policy.isProtected(d6s2, allDisks: all))
    }

    @Test func protectedVolumeKindAloneProtectsSiblings() {
        let policy = ProtectionPolicy()
        let ntfs = disk("disk7s1", whole: "disk7", kind: "ntfs")
        let apfs = disk("disk7s2", whole: "disk7", kind: "apfs")
        #expect(policy.isProtected(ntfs, allDisks: [ntfs, apfs]))
    }

    @Test func gptNTFSWithAPFSGUIDSiblingIsProtected() {
        let policy = ProtectionPolicy()
        let ntfs = disk("disk9s1", whole: "disk9", kind: "ntfs", content: "EBD0A0A2-B9E5-4433-87C0-68B6B72699C7")
        let apfs = disk("disk9s2", whole: "disk9", content: "7C3457EF-0000-11AA-AA11-00306543ECAC")
        #expect(policy.isProtected(ntfs, allDisks: [ntfs, apfs]))
    }

    @Test func gptNTFSWithExFATSiblingIsNotProtected() {
        let policy = ProtectionPolicy()
        let ntfs = disk("disk9s1", whole: "disk9", kind: "ntfs", content: "EBD0A0A2-B9E5-4433-87C0-68B6B72699C7")
        let exfat = disk("disk9s2", whole: "disk9", kind: "exfat", content: "EBD0A0A2-B9E5-4433-87C0-68B6B72699C7")
        #expect(!policy.isProtected(ntfs, allDisks: [ntfs, exfat]))
    }

    @Test func allAppleGPTGUIDsAreProtected() {
        let policy = ProtectionPolicy()
        let guids = [
            "69646961-6700-11AA-AA11-00306543ECAC", "7C3457EF-0000-11AA-AA11-00306543ECAC",
            "52637672-7900-11AA-AA11-00306543ECAC", "EF57347C-0000-11AA-AA11-00306543ECAC",
            "41504653-0000-11AA-AA11-00306543ECAC", "48465300-0000-11AA-AA11-00306543ECAC",
            "426F6F74-0000-11AA-AA11-00306543ECAC",
        ]
        for guid in guids {
            let d = disk("disk11s1", whole: "disk11", content: guid)
            #expect(policy.isProtected(d, allDisks: [d]), "\(guid)")
        }
    }

    @Test func coreStorageAndAppleRAIDAreProtected() {
        let policy = ProtectionPolicy()
        let types = [
            "53746F72-6167-11AA-AA11-00306543ECAC",  // CoreStorage
            "52414944-0000-11AA-AA11-00306543ECAC",  // Apple RAID
            "52414944-5F4F-11AA-AA11-00306543ECAC",  // Apple RAID, offline
            "Apple_CoreStorage", "Apple_RAID", "Apple_RAID_Offline",
        ]
        for type in types {
            let member = disk("disk12s2", whole: "disk12", content: type)
            let ntfs = disk("disk12s3", whole: "disk12", kind: "ntfs", content: "Microsoft Basic Data")
            #expect(policy.isProtected(member, allDisks: [member, ntfs]), "\(type)")
            #expect(policy.isProtected(ntfs, allDisks: [member, ntfs]), "\(type)")
        }
    }

    @Test func matchingIsCaseInsensitive() {
        let policy = ProtectionPolicy()
        let upperKind = disk("disk12s1", whole: "disk12", kind: "APFS")
        #expect(policy.isProtected(upperKind, allDisks: [upperKind]))
        let lowerGUID = disk("disk13s1", whole: "disk13", content: "7c3457ef-0000-11aa-aa11-00306543ecac")
        #expect(policy.isProtected(lowerGUID, allDisks: [lowerGUID]))
    }

    @Test func internalNonBootSDCardIsAllowed() {
        let policy = ProtectionPolicy(bootWholeDisks: ["disk0"])
        let sd = disk("disk2s1", whole: "disk2", internal: true, kind: "ntfs", content: "Microsoft Basic Data")
        #expect(!policy.isProtected(sd, allDisks: [sd]))
    }

    @Test func diskImagesProtectedUnlessAllowed() {
        let image = disk("disk8s1", whole: "disk8", image: true, kind: "ntfs", content: "Microsoft Basic Data")
        #expect(ProtectionPolicy().isProtected(image, allDisks: [image]))
        #expect(!ProtectionPolicy(allowDiskImages: true).isProtected(image, allDisks: [image]))
    }

    @Test func parsesBootWholeDisks() throws {
        let stores = try plist(["APFSPhysicalStores": [["APFSPhysicalStore": "disk0s2"]]])
        #expect(ProtectionPolicy.bootWholeDisks(fromDiskutilInfoPlist: stores) == ["disk0"])

        let two = try plist(["APFSPhysicalStores": [
            ["APFSPhysicalStore": "disk0s2"], ["APFSPhysicalStore": "disk1s2"],
        ]])
        #expect(ProtectionPolicy.bootWholeDisks(fromDiskutilInfoPlist: two) == ["disk0", "disk1"])

        let multiDigit = try plist(["APFSPhysicalStores": [["APFSPhysicalStore": "disk10s2"]]])
        #expect(ProtectionPolicy.bootWholeDisks(fromDiskutilInfoPlist: multiDigit) == ["disk10"])

        let fallback = try plist(["ParentWholeDisk": "disk3"])
        #expect(ProtectionPolicy.bootWholeDisks(fromDiskutilInfoPlist: fallback) == ["disk3"])
    }

    @Test func malformedOrEmptyPlistGivesEmptySet() throws {
        #expect(ProtectionPolicy.bootWholeDisks(fromDiskutilInfoPlist: Data()).isEmpty)
        #expect(ProtectionPolicy.bootWholeDisks(fromDiskutilInfoPlist: Data("not a plist".utf8)).isEmpty)
        #expect(ProtectionPolicy.bootWholeDisks(fromDiskutilInfoPlist: try plist([:])).isEmpty)
    }
}

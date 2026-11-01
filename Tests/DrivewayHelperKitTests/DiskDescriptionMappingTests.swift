import CoreFoundation
import DrivewayCore
import DrivewayHelperKit
import Foundation
import Testing

private let volumeUUID = "0B5E1F7C-3D2A-4C11-9E8F-2A6B7C8D9E01"
private let mediaUUID = "5A1C2B3D-4E5F-4061-8723-94A5B6C7D8E9"

private func cfuuid(_ s: String) -> CFUUID { CFUUIDCreateFromString(kCFAllocatorDefault, s as CFString) }

@Test func daDescriptionMapping() {
    let description: [String: Any] = [
        "DAMediaBSDName": "disk4s1",
        "DAMediaWhole": false,
        "DADeviceInternal": false,
        "DADeviceModel": "Portable SSD T7",
        "DAMediaContent": "EBD0A0A2-B9E5-4433-87C0-68B6B72699C7",
        "DAMediaSize": NSNumber(value: Int64(500_107_862_016)),
        "DAVolumeKind": "ntfs",
        "DAVolumeType": "Windows_NTFS",
        "DAVolumeName": "BACKUP",
        "DAVolumeUUID": cfuuid(volumeUUID),
        "DAMediaUUID": cfuuid(mediaUUID),
        "DAVolumePath": URL(fileURLWithPath: "/Volumes/BACKUP", isDirectory: true),
    ]
    let d = DiskDescription(daDescription: description, bsdName: "disk4s1")
    #expect(d.bsdName == "disk4s1")
    #expect(d.wholeDisk == "disk4")
    #expect(!d.isWholeMedia)
    #expect(!d.isInternal)
    #expect(!d.isDiskImage)
    #expect(d.deviceModel == "Portable SSD T7")
    #expect(d.contentType == "EBD0A0A2-B9E5-4433-87C0-68B6B72699C7")
    #expect(d.sizeBytes == 500_107_862_016)
    #expect(d.volumeKind == "ntfs")
    #expect(d.volumeType == "Windows_NTFS")
    #expect(d.volumeName == "BACKUP")
    #expect(d.volumeUUID == volumeUUID)
    #expect(d.mediaUUID == mediaUUID)
    #expect(d.volumePath == "/Volumes/BACKUP")
}

@Test func daDescriptionMappingStringsAndDiskImages() {
    let description: [String: Any] = [
        "DAMediaBSDName": "disk12",
        "DAMediaWhole": true,
        "DADeviceInternal": true,
        "DADeviceModel": "Disk Image",
        "DAMediaSize": 1_073_741_824,
        "DAVolumeUUID": volumeUUID,
        "DAMediaUUID": mediaUUID,
    ]
    let d = DiskDescription(daDescription: description, bsdName: "disk12")
    #expect(d.wholeDisk == "disk12")
    #expect(d.isWholeMedia)
    #expect(d.isInternal)
    #expect(d.isDiskImage)
    #expect(d.sizeBytes == 1_073_741_824)
    #expect(d.volumeUUID == volumeUUID)
    #expect(d.mediaUUID == mediaUUID)
}

@Test func daDescriptionMappingMissingKeys() {
    let d = DiskDescription(daDescription: [:], bsdName: "disk7s3")
    #expect(d.bsdName == "disk7s3")
    #expect(d.wholeDisk == "disk7")
    #expect(!d.isWholeMedia)
    #expect(!d.isInternal)
    #expect(!d.isDiskImage)
    #expect(d.volumeKind == nil)
    #expect(d.volumeType == nil)
    #expect(d.contentType == nil)
    #expect(d.volumeName == nil)
    #expect(d.volumeUUID == nil)
    #expect(d.mediaUUID == nil)
    #expect(d.sizeBytes == 0)
    #expect(d.deviceModel == "")
    #expect(d.volumePath == nil)
}

@Test func usedBytesArithmetic() {
    #expect(DADiskInventory.usedBytes(blocks: 1_000, free: 400, blockSize: 4_096) == Int64(2_457_600))
    #expect(DADiskInventory.usedBytes(blocks: 0, free: 0, blockSize: 4_096) == 0)
    // More free than total (a confused FUSE filesystem): 0, not a crash.
    #expect(DADiskInventory.usedBytes(blocks: 10, free: 20, blockSize: 4_096) == 0)
    // Doesn't fit in Int64: nil, not a crash.
    #expect(DADiskInventory.usedBytes(blocks: UInt64.max, free: 0, blockSize: 1) == nil)
    #expect(DADiskInventory.usedBytes(blocks: UInt64(Int64.max), free: 0, blockSize: 2) == nil)
    #expect(DADiskInventory.usedBytes(blocks: UInt64(Int64.max), free: 0, blockSize: 1) == Int64.max)
}

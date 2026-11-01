import Testing

@testable import DrivewayCore

private let p = ToolPaths()
private let diskutil = "/usr/sbin/diskutil"

func req(
    _ fs: FilesystemKind, _ label: String, _ target: FormatTarget = .wholeDisk("disk4"),
    scheme: PartitionScheme = .gpt, confirm: String = "BACKUP"
) -> FormatRequest {
    FormatRequest(filesystem: fs, label: label, scheme: scheme, target: target, confirmation: confirm, expectedKey: "K")
}

private func disk(
    _ name: String, whole: String = "disk4", wholeMedia: Bool = false, content: String?, size: Int64
) -> DiskDescription {
    DiskDescription(
        bsdName: name, wholeDisk: whole, isWholeMedia: wholeMedia, isInternal: false, isDiskImage: false,
        volumeKind: nil, volumeType: nil, contentType: content, volumeName: nil, volumeUUID: nil,
        mediaUUID: nil, sizeBytes: size, deviceModel: "X", volumePath: nil)
}

@Test func confirmationMustMatchDriveName() {
    #expect(throws: FormatValidationError.confirmationMismatch) {
        try validate(req(.ntfs, "NEW", confirm: "backup"), currentDriveName: "BACKUP")
    }
    // trims whitespace only
    #expect(throws: Never.self) {
        try validate(req(.ntfs, "NEW", confirm: "  BACKUP "), currentDriveName: "BACKUP")
    }
}

@Test func labelLimits() {
    #expect(throws: FormatValidationError.emptyLabel) {
        try validate(req(.ntfs, " "), currentDriveName: "BACKUP")
    }
    #expect(throws: FormatValidationError.labelTooLong(max: 32)) {
        try validate(req(.ntfs, String(repeating: "a", count: 33)), currentDriveName: "BACKUP")
    }
    // 18 UTF-8 bytes
    #expect(throws: FormatValidationError.labelTooLong(max: 16)) {
        try validate(req(.ext4, "ПРИВЕТМИР"), currentDriveName: "BACKUP")
    }
    #expect(throws: FormatValidationError.labelTooLong(max: 11)) {
        try validate(req(.fat32, "ABCDEFGHIJKL"), currentDriveName: "BACKUP")
    }
    #expect(throws: FormatValidationError.invalidCharacters) {
        try validate(req(.fat32, "A:B"), currentDriveName: "BACKUP")
    }
    #expect(throws: FormatValidationError.unsupportedFilesystem) {
        try validate(req(.ext2, "X"), currentDriveName: "BACKUP")
    }
}

@Test func labelsAtTheLimitAreAccepted() {
    #expect(throws: Never.self) {
        try validate(req(.ntfs, String(repeating: "a", count: 32)), currentDriveName: "BACKUP")
        try validate(req(.ext4, "ПРИВЕТМИ"), currentDriveName: "BACKUP")  // 16 UTF-8 bytes
        try validate(req(.exfat, "ABCDEFGHIJK"), currentDriveName: "BACKUP")
        try validate(req(.fat32, "My_Disk-1 !"), currentDriveName: "BACKUP")  // 11 allowed characters
    }
}

@Test func fat32AllowedPunctuation() {
    #expect(throws: Never.self) {
        try validate(req(.fat32, "_-!#$%&'()"), currentDriveName: "BACKUP")
        try validate(req(.fat32, "@^{}~"), currentDriveName: "BACKUP")
    }
    for bad in ["A.B", "A+B", "A/B", "A*B", "ÄB"] {
        #expect(throws: FormatValidationError.invalidCharacters) {
            try validate(req(.fat32, bad), currentDriveName: "BACKUP")
        }
    }
}

@Test func controlCharactersAreRejectedEverywhere() {
    for fs in [FilesystemKind.ntfs, .ext4, .exfat, .fat32] {
        #expect(throws: FormatValidationError.invalidCharacters) {
            try validate(req(fs, "A\nB"), currentDriveName: "BACKUP")
        }
    }
}

@Test func validationOrderIsLabelBeforeConfirmation() {
    #expect(throws: FormatValidationError.emptyLabel) {
        try validate(req(.ntfs, " ", confirm: "nope"), currentDriveName: "BACKUP")
    }
    #expect(throws: FormatValidationError.unsupportedFilesystem) {
        try validate(req(.other, "", confirm: "nope"), currentDriveName: "BACKUP")
    }
}

@Test func wholeDiskExfatIsOneDiskutilCall() {
    #expect(
        FormatPlanner.eraseCommands(req(.exfat, "CAM"), paths: p)
            == [Command(executable: diskutil, arguments: ["eraseDisk", "ExFAT", "CAM", "GPT", "/dev/disk4"])])
    #expect(FormatPlanner.finishCommands(req(.exfat, "CAM"), dataPartition: "disk4s2", paths: p) == [])
}

@Test func wholeDiskFat32UsesMBRWhenAsked() {
    #expect(
        FormatPlanner.eraseCommands(req(.fat32, "CAM", scheme: .mbr), paths: p).map(\.arguments)
            == [["eraseDisk", "MS-DOS FAT32", "CAM", "MBR", "/dev/disk4"]])
    #expect(
        FormatPlanner.finishCommands(req(.fat32, "CAM", scheme: .mbr), dataPartition: "disk4s1", paths: p) == [])
}

@Test func wholeDiskNTFSErasesThenMkntfs() {
    #expect(
        FormatPlanner.eraseCommands(req(.ntfs, "BACKUP"), paths: p).map(\.arguments)
            == [["eraseDisk", "ExFAT", "DRIVEWAYTMP", "GPT", "/dev/disk4"]])
    #expect(
        FormatPlanner.finishCommands(req(.ntfs, "BACKUP"), dataPartition: "disk4s2", paths: p) == [
            Command(executable: diskutil, arguments: ["unmount", "/dev/disk4s2"]),
            Command(
                executable: "/opt/homebrew/sbin/mkntfs",
                arguments: ["--quick", "--label", "BACKUP", "/dev/disk4s2"]),
        ])
}

@Test func wholeDiskExt4ErasesThenMkfs() {
    #expect(
        FormatPlanner.eraseCommands(req(.ext4, "DATA", scheme: .mbr), paths: p).map(\.arguments)
            == [["eraseDisk", "ExFAT", "DRIVEWAYTMP", "MBR", "/dev/disk4"]])
    #expect(
        FormatPlanner.finishCommands(req(.ext4, "DATA"), dataPartition: "disk4s2", paths: p) == [
            Command(executable: diskutil, arguments: ["unmount", "/dev/disk4s2"]),
            Command(
                executable: "/opt/homebrew/opt/e2fsprogs/sbin/mkfs.ext4",
                arguments: ["-F", "-L", "DATA", "/dev/disk4s2"]),
        ])
}

@Test func partitionExt4RetagsThenMkfs() {
    let r = req(.ext4, "LBL", .partition("disk4s2"))
    #expect(
        FormatPlanner.eraseCommands(r, paths: p)
            == [
                Command(
                    executable: diskutil,
                    arguments: ["eraseVolume", "ExFAT", "DRIVEWAYTMP", "/dev/disk4s2"])
            ])
    #expect(
        FormatPlanner.finishCommands(r, dataPartition: "disk4s2", paths: p)
            == [
                Command(executable: diskutil, arguments: ["unmount", "/dev/disk4s2"]),
                Command(
                    executable: "/opt/homebrew/opt/e2fsprogs/sbin/mkfs.ext4",
                    arguments: ["-F", "-L", "LBL", "/dev/disk4s2"]),
            ])
}

@Test func partitionNtfsRetagsThenMkntfs() {
    let r = req(.ntfs, "LBL", .partition("disk4s2"))
    #expect(
        FormatPlanner.eraseCommands(r, paths: p)
            == [
                Command(
                    executable: diskutil,
                    arguments: ["eraseVolume", "ExFAT", "DRIVEWAYTMP", "/dev/disk4s2"])
            ])
    #expect(
        FormatPlanner.finishCommands(r, dataPartition: "disk4s2", paths: p)
            == [
                Command(executable: diskutil, arguments: ["unmount", "/dev/disk4s2"]),
                Command(
                    executable: "/opt/homebrew/sbin/mkntfs",
                    arguments: ["--quick", "--label", "LBL", "/dev/disk4s2"]),
            ])
}

@Test func partitionFinishIgnoresTheDataPartitionArgument() {
    let r = req(.ntfs, "LBL", .partition("disk4s2"))
    #expect(
        FormatPlanner.finishCommands(r, dataPartition: "disk9s1", paths: p)
            == FormatPlanner.finishCommands(r, dataPartition: "disk4s2", paths: p))
    #expect(
        FormatPlanner.finishCommands(r, dataPartition: "disk9s1", paths: p).map(\.arguments).last
            == ["--quick", "--label", "LBL", "/dev/disk4s2"])
}

@Test func wholeDiskFinishRequiresAPartitionOfThatDisk() {
    for bad in ["disk40s1", "disk5s2", "disk4", "disk4s", "disk4s2x", "disk4s1s2", "", "../disk4s2", "disk4s٢"] {
        #expect(FormatPlanner.finishCommands(req(.ntfs, "X"), dataPartition: bad, paths: p) == [], "\(bad)")
        #expect(FormatPlanner.finishCommands(req(.ext4, "X"), dataPartition: bad, paths: p) == [], "\(bad)")
    }
    #expect(FormatPlanner.finishCommands(req(.ntfs, "X"), dataPartition: "disk4s12", paths: p).count == 2)
}

@Test func invalidTargetsAreRejected() {
    for target in [
        FormatTarget.partition("disk4"), .wholeDisk("disk4s2"), .partition("../x"), .wholeDisk(""),
        .wholeDisk("disk"), .partition("disk4s"), .partition("disk4s2 "), .wholeDisk("/dev/disk4"),
        .partition("disk4s2/../disk0"),
    ] {
        #expect(throws: FormatValidationError.invalidTarget) {
            try validate(req(.ntfs, "X", target), currentDriveName: "BACKUP")
        }
    }
    #expect(throws: Never.self) {
        try validate(req(.ntfs, "X", .partition("disk12s34")), currentDriveName: "BACKUP")
        try validate(req(.ntfs, "X", .wholeDisk("disk12")), currentDriveName: "BACKUP")
    }
}

@Test func invalidTargetIsCheckedFirst() {
    #expect(throws: FormatValidationError.invalidTarget) {
        try validate(req(.ext2, "", .wholeDisk("x"), confirm: "no"), currentDriveName: "BACKUP")
    }
}

@Test func emptyDriveNameCanNeverBeConfirmed() {
    for name in ["", "   ", "\n"] {
        #expect(throws: FormatValidationError.confirmationMismatch) {
            try validate(req(.ntfs, "NEW", confirm: ""), currentDriveName: name)
        }
        #expect(throws: FormatValidationError.confirmationMismatch) {
            try validate(req(.ntfs, "NEW", confirm: name), currentDriveName: name)
        }
    }
}

@Test func emojiCountsAsTwoUTF16UnitsForExfat() {
    #expect(throws: FormatValidationError.labelTooLong(max: 11)) {
        try validate(req(.exfat, "ABCDEFGHIJ😀"), currentDriveName: "BACKUP")
    }
    #expect(throws: Never.self) {
        try validate(req(.exfat, "ABCDEFGHI😀"), currentDriveName: "BACKUP")
    }
}

@Test func ntfsReservedCharactersAreRejected() {
    #expect(throws: FormatValidationError.invalidCharacters) {
        try validate(req(.ntfs, "A?B"), currentDriveName: "BACKUP")
    }
}

@Test func tooLongBeatsInvalidCharactersBeatsConfirmation() {
    #expect(throws: FormatValidationError.labelTooLong(max: 11)) {
        try validate(req(.fat32, "A:BCDEFGHIJKL", confirm: "no"), currentDriveName: "BACKUP")
    }
    #expect(throws: FormatValidationError.invalidCharacters) {
        try validate(req(.fat32, "A:B", confirm: "no"), currentDriveName: "BACKUP")
    }
}

@Test func partitionExfatUsesEraseVolume() {
    let r = req(.exfat, "CAM", .partition("disk4s2"))
    #expect(
        FormatPlanner.eraseCommands(r, paths: p).map(\.arguments)
            == [["eraseVolume", "ExFAT", "CAM", "/dev/disk4s2"]])
    #expect(FormatPlanner.finishCommands(r, dataPartition: "disk4s2", paths: p) == [])
}

@Test func partitionFat32UsesEraseVolume() {
    let r = req(.fat32, "CAM", .partition("disk4s2"))
    #expect(
        FormatPlanner.eraseCommands(r, paths: p)
            == [
                Command(
                    executable: diskutil, arguments: ["eraseVolume", "MS-DOS FAT32", "CAM", "/dev/disk4s2"])
            ])
    #expect(FormatPlanner.finishCommands(r, dataPartition: "disk4s2", paths: p) == [])
}

@Test func dataPartitionIsLargestNonEFI() {
    let disks = [
        disk("disk4", wholeMedia: true, content: "GUID_partition_scheme", size: 1_000_000_000_000),
        disk("disk4s1", content: "EFI", size: 200_000_000),
        disk("disk4s2", content: "Microsoft Basic Data", size: 1_000_000_000_000),
        disk("disk4s3", content: "Microsoft Basic Data", size: 5_000_000_000),
        disk("disk5s2", whole: "disk5", content: "Microsoft Basic Data", size: 9_000_000_000_000),
    ]
    #expect(FormatPlanner.dataPartition(of: "disk4", in: disks) == "disk4s2")
}

@Test func dataPartitionRecognisesEFIByGUID() {
    let disks = [
        disk("disk4s1", content: "c12a7328-f81f-11d2-ba4b-00a0c93ec93b", size: 900_000_000_000),
        disk("disk4s2", content: "EBD0A0A2-B9E5-4433-87C0-68B6B72699C7", size: 500_000_000_000),
    ]
    #expect(FormatPlanner.dataPartition(of: "disk4", in: disks) == "disk4s2")
}

@Test func dataPartitionIsNilWhenNothingQualifies() {
    #expect(FormatPlanner.dataPartition(of: "disk4", in: []) == nil)
    let onlyEFIAndWhole = [
        disk("disk4", wholeMedia: true, content: "GUID_partition_scheme", size: 1_000_000_000_000),
        disk("disk4s1", content: "EFI", size: 200_000_000),
        disk("disk5s2", whole: "disk5", content: "Microsoft Basic Data", size: 9_000_000_000_000),
    ]
    #expect(FormatPlanner.dataPartition(of: "disk4", in: onlyEFIAndWhole) == nil)
}

@Test func warningText() {
    #expect(eraseWarning(label: "BACKUP", capacityBytes: 620_000_000_000) == "All 620 GB on BACKUP will be erased")
}

@Test func olderPCsCopy() {
    #expect(Copy.forOlderPCs == "for older PCs")
}

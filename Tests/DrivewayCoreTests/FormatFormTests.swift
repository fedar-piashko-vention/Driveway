import Foundation
import Testing

@testable import DrivewayCore

private func vol(
    _ bsd: String, whole: String = "disk4", label: String, bytes: Int64 = 1_000_000_000,
    fs: FilesystemKind = .ntfs
) -> Volume {
    Volume(
        bsdName: bsd, wholeDisk: whole, label: label, filesystem: fs, capacityBytes: bytes, usedBytes: nil,
        mountPoint: nil, access: .readWrite, health: .clean, mountedBy: .driveway, deviceModel: "SSD",
        settingsKey: "k-\(bsd)", lastError: nil)
}

struct FormatMessagesTests {
    @Test func labelErrorsHaveSpecCopy() {
        #expect(FormatMessages.text(for: .labelTooLong(max: 11)) == "Name can be at most 11 characters")
        #expect(FormatMessages.text(for: .labelTooLong(max: 32)) == "Name can be at most 32 characters")
        #expect(FormatMessages.text(for: .invalidCharacters) == "Name contains characters this format can't use")
        #expect(FormatMessages.text(for: .emptyLabel) == "Enter a name")
    }

    @Test func otherErrorsHaveShortSentences() {
        for error in [FormatValidationError.confirmationMismatch, .invalidTarget, .unsupportedFilesystem] {
            let text = FormatMessages.text(for: error)
            #expect(!text.isEmpty)
            #expect(text.hasSuffix("."))
        }
        #expect(
            FormatMessages.text(for: .confirmationMismatch) != FormatMessages.text(for: .invalidTarget))
    }

    @Test func onlyLabelErrorsShowInline() {
        #expect(FormatMessages.isLabelError(.emptyLabel))
        #expect(FormatMessages.isLabelError(.labelTooLong(max: 5)))
        #expect(FormatMessages.isLabelError(.invalidCharacters))
        #expect(!FormatMessages.isLabelError(.confirmationMismatch))
        #expect(!FormatMessages.isLabelError(.invalidTarget))
        #expect(!FormatMessages.isLabelError(.unsupportedFilesystem))
    }

    @Test func inlineErrorValidatesWithTheDriveName() {
        let target = FormatTarget.partition("disk4s2")
        // A good name shows nothing, although the confirmation is not typed yet.
        #expect(
            FormatMessages.inlineError(filesystem: .exfat, label: "NEW", scheme: .gpt, target: target, driveName: "BACKUP")
                == nil)
        #expect(
            FormatMessages.inlineError(filesystem: .exfat, label: "", scheme: .gpt, target: target, driveName: "BACKUP")
                == "Enter a name")
        #expect(
            FormatMessages.inlineError(
                filesystem: .exfat, label: "TWELVECHARSX", scheme: .gpt, target: target, driveName: "BACKUP")
                == "Name can be at most 11 characters")
        // Not a label error: not shown inline.
        #expect(
            FormatMessages.inlineError(filesystem: .exfat, label: "OK", scheme: .gpt, target: .partition("bogus"), driveName: "BACKUP")
                == nil)
    }
}

struct FormatFormTests {
    private let a = vol("disk4s2", label: "DATA", bytes: 2_000_000_000)
    private let b = vol("disk4s3", label: "PHOTOS", bytes: 3_000_000_000)
    private let other = vol("disk5s1", whole: "disk5", label: "OTHER")

    @Test func wholeDiskDefaultsOnWhenAloneOnItsDisk() {
        #expect(FormatForm.defaultsToWholeDisk(a, in: [a, other]))
        #expect(!FormatForm.defaultsToWholeDisk(a, in: [a, b, other]))
    }

    @Test func targetFollowsTheToggle() {
        #expect(FormatForm.target(for: a, wholeDisk: true) == .wholeDisk("disk4"))
        #expect(FormatForm.target(for: a, wholeDisk: false) == .partition("disk4s2"))
    }

    @Test func partitionWarningUsesTheVolume() {
        #expect(
            FormatForm.warning(for: a, wholeDisk: false, in: [a, b])
                == [eraseWarning(label: "DATA", capacityBytes: 2_000_000_000)])
    }

    @Test func wholeDiskWarningSumsAndNamesTheOthers() {
        let lines = FormatForm.warning(for: a, wholeDisk: true, in: [a, b, other])
        #expect(lines == [eraseWarning(label: "DATA", capacityBytes: 5_000_000_000), "This also erases: PHOTOS"])
        let c = vol("disk4s4", label: "X Y", bytes: 1)
        let three = FormatForm.warning(for: a, wholeDisk: true, in: [a, b, c])
        #expect(three.last == "This also erases: PHOTOS, X Y")
    }

    @Test func wholeDiskWarningForALoneVolumeIsOneLine() {
        #expect(
            FormatForm.warning(for: a, wholeDisk: true, in: [a, other])
                == [eraseWarning(label: "DATA", capacityBytes: 2_000_000_000)])
    }

    @Test func gatingFollowsReadyFeatures() {
        let all = Set(Feature.allCases)
        for fs in [FilesystemKind.exfat, .fat32] {
            #expect(FormatForm.isAvailable(fs, ready: []))
        }
        #expect(FormatForm.isAvailable(.ntfs, ready: all))
        #expect(!FormatForm.isAvailable(.ntfs, ready: all.subtracting([.writeNTFS])))
        #expect(FormatForm.isAvailable(.ext4, ready: all))
        #expect(!FormatForm.isAvailable(.ext4, ready: all.subtracting([.extDrives])))
        #expect(FormatForm.unavailableReason(.ntfs, ready: []) != nil)
        #expect(FormatForm.unavailableReason(.ntfs, ready: all) == nil)
        #expect(FormatForm.unavailableReason(.exfat, ready: []) == nil)
    }

    @Test func disabledChoiceFallsBackToExFAT() {
        #expect(FormatForm.effective(.ntfs, ready: []) == .exfat)
        #expect(FormatForm.effective(.ext4, ready: [.writeNTFS]) == .exfat)
        #expect(FormatForm.effective(.ntfs, ready: [.writeNTFS]) == .ntfs)
        #expect(FormatForm.effective(.fat32, ready: []) == .fat32)
    }

    @Test func choicesAreTheFourFilesystemsInOrder() {
        #expect(FormatForm.choices == [.ntfs, .ext4, .exfat, .fat32])
    }

    @Test func schemeCopy() {
        #expect(FormatForm.schemeTitle(.gpt) == "GPT")
        #expect(FormatForm.schemeTitle(.mbr) == "MBR — for older PCs")
    }

    @Test func wholeMediaWithoutPartitionTableAlwaysErasesTheWholeDisk() {
        let bare = vol("disk4", label: "RAW")
        #expect(FormatForm.isWholeDiskForced(bare))
        #expect(FormatForm.defaultsToWholeDisk(bare, in: [bare, vol("disk4s1", label: "X")]))
        #expect(FormatForm.erasesWholeDisk(bare, toggle: false))
        #expect(!FormatForm.isWholeDiskForced(a))
        #expect(!FormatForm.erasesWholeDisk(a, toggle: false))
        #expect(FormatForm.erasesWholeDisk(a, toggle: true))
    }

    @Test func busyCoversTheWholeDiskOnlyWhenErasingIt() {
        #expect(FormatForm.isBusy(a, wholeDisk: false, busy: ["disk4s2"]))
        #expect(!FormatForm.isBusy(a, wholeDisk: false, busy: ["disk4s3"]))
        #expect(FormatForm.isBusy(a, wholeDisk: true, busy: ["disk4s3"]))
        #expect(FormatForm.isBusy(a, wholeDisk: true, busy: ["disk4"]))
        #expect(!FormatForm.isBusy(a, wholeDisk: true, busy: ["disk5s1", "disk40s1"]))
        #expect(!FormatForm.isBusy(a, wholeDisk: true, busy: []))
    }

    @Test func summaryLeavesOutTheSchemeForAPartition() {
        #expect(FormatForm.summary(of: req(.ntfs, "N", .wholeDisk("disk4"), scheme: .gpt)) == "NTFS · GPT · whole disk")
        #expect(FormatForm.summary(of: req(.exfat, "N", .wholeDisk("disk4"), scheme: .mbr)) == "exFAT · MBR · whole disk")
        #expect(FormatForm.summary(of: req(.fat32, "N", .partition("disk4s2"), scheme: .mbr)) == "FAT32 · this partition")
    }
}

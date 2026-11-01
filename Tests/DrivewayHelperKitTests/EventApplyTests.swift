import DrivewayCore
import DrivewayIPC
import Testing

private func volume(_ bsd: String, label: String = "DRIVE", access: AccessMode = .readWrite) -> Volume {
    Volume(
        bsdName: bsd, wholeDisk: "disk4", label: label, filesystem: .ntfs, capacityBytes: 10, usedBytes: 5,
        mountPoint: "/Volumes/\(label)", access: access, health: .clean, mountedBy: .driveway,
        deviceModel: "SSD", settingsKey: "K-\(bsd)", lastError: nil)
}

struct EventApplyTests {
    @Test func mountedReplacesByBSDNameOrAppends() {
        let a = volume("disk4s1", label: "A")
        let b = volume("disk5s1", label: "B")
        let renamed = volume("disk4s1", label: "A2")
        #expect(VolumeEvent.mounted(renamed).applied(to: [a, b]) == [renamed, b])

        let c = volume("disk6s1", label: "C")
        #expect(VolumeEvent.mounted(c).applied(to: [a, b]) == [a, b, c])
        #expect(VolumeEvent.mounted(c).applied(to: []) == [c])
    }

    @Test func removedDeletes() {
        let a = volume("disk4s1")
        let b = volume("disk5s1")
        #expect(VolumeEvent.removed(bsdName: "disk4s1").applied(to: [a, b]) == [b])
        #expect(VolumeEvent.removed(bsdName: "disk9s1").applied(to: [a, b]) == [a, b])
    }

    @Test func progressLeavesTheListAndSelectionAlone() {
        let a = volume("disk4s1")
        let event = VolumeEvent.progress(bsdName: "disk4s1", operation: .backup, fraction: 0.5)
        #expect(event.applied(to: [a]) == [a])
        #expect(event.selection(after: "disk4s1") == "disk4s1")
    }

    @Test func mountedReadOnlyReplaces() {
        let a = volume("disk4s1")
        var readOnly = a
        readOnly.access = .readOnly
        readOnly.health = .dirty
        #expect(VolumeEvent.mountedReadOnly(readOnly, reason: .dirty).applied(to: [a]) == [readOnly])
    }

    @Test func backedOffAndMountFailedUpsert() {
        let a = volume("disk4s1")
        var owned = a
        owned.mountedBy = .otherDriver("Tuxera NTFS")
        #expect(VolumeEvent.backedOff(owned, driver: "Tuxera NTFS").applied(to: [a]) == [owned])

        var failed = volume("disk5s1", access: .notMounted)
        failed.lastError = "boom"
        #expect(VolumeEvent.mountFailed(failed, message: "boom").applied(to: [a]) == [a, failed])
    }
}

@Test func removalClearsTheSelectionOfThatDriveOnly() {
    #expect(VolumeEvent.removed(bsdName: "disk4s1").selection(after: "disk4s1") == nil)
    #expect(VolumeEvent.removed(bsdName: "disk4s1").selection(after: "disk5s1") == "disk5s1")
    #expect(VolumeEvent.removed(bsdName: "disk4s1").selection(after: nil) == nil)
}

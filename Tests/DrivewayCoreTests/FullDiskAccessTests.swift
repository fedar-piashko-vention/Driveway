import Foundation
import Testing
@testable import DrivewayCore

struct FullDiskAccessTests {
    let full = ToolInventory(
        hasHomebrew: true, macFUSEVersion: SemanticVersion("5.5.0"), backend: .ready(.kernel), hasNTFS3G: true,
        hasExt4fuse: true, hasE2fsprogs: true, helperVersion: "1.0.0", appVersion: "1.0.0", conflictingDrivers: [])

    @Test func unknownUntilTheHelperAnswers() {
        #expect(full.fullDiskAccess == nil)
        #expect(readyCount(featureStates(full, ntfsWriteSupported: true)) == 4)
    }

    @Test func everyFeatureThatTouchesADriveNeedsIt() {
        var inv = full
        inv.fullDiskAccess = false
        let states = featureStates(inv, ntfsWriteSupported: true)
        #expect(states[.readNTFS] == .ready)
        #expect(states[.writeNTFS] == .locked(missing: [.fullDiskAccess]))
        #expect(states[.repairNTFS] == .locked(missing: [.fullDiskAccess]))
        #expect(states[.extDrives] == .locked(missing: [.fullDiskAccess]))

        inv.fullDiskAccess = true
        #expect(readyCount(featureStates(inv, ntfsWriteSupported: true)) == 4)
    }

    @Test func listedOnlyOnceTheHelperIsInstalledAndComesAfterIt() {
        var inv = full
        inv.fullDiskAccess = false
        inv.helperVersion = nil
        #expect(featureStates(inv, ntfsWriteSupported: true)[.writeNTFS] == .locked(missing: [.helper]))

        inv.helperVersion = "0.9.0"
        inv.hasNTFS3G = false
        #expect(
            featureStates(inv, ntfsWriteSupported: true)[.writeNTFS]
                == .locked(missing: [.ntfs3g, .helperUpdate, .fullDiskAccess]))
    }

    @Test func unlockOrderPutsItAfterTheHelper() {
        var inv = full
        inv.fullDiskAccess = false
        inv.helperVersion = "0.9.0"
        inv.hasExt4fuse = false
        let states = featureStates(inv, ntfsWriteSupported: true)
        let order = SetupScreen.unlockOrder(for: Feature.allCases, in: states)
        #expect(order == [.ext4fuse, .helperUpdate, .fullDiskAccess])
        #expect(SetupScreen.runNow(order) == order)
        #expect(SetupScreen.buttonTitle(for: [.fullDiskAccess]) == Copy.openSettings)
    }

    @Test func stepOpensTheFullDiskAccessPane() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
        #expect(InstallStep.for(.fullDiskAccess) == .openSettings(url))
        #expect(InstallStep.for(.fullDiskAccess).continuesOutsideDriveway)
    }

    @Test func setupRowIsAnApprovalWithTheHelperPath() {
        var inv = full
        inv.fullDiskAccess = false
        let write = SetupScreen.groups(featureStates(inv, ntfsWriteSupported: true))[1]
        #expect(write.items.map(\.requirement) == [.fullDiskAccess])
        #expect(write.items[0].symbol == "⚠️")
        #expect(write.items[0].label == "Driveway helper — needs Full Disk Access in System Settings → Privacy & Security")

        #expect(FullDiskAccess.helperAppPath == "/Library/PrivilegedHelperTools/app.driveway.helper.app")
        let steps = Copy.afterHandoff(.fullDiskAccess) ?? ""
        #expect(steps.contains(FullDiskAccess.helperAppPath))
        #expect(steps.contains("+"))
        #expect(steps.contains("⌘⇧G"))
        #expect(steps.contains("turn it on"))
        #expect(steps.contains("Tuxera"))
    }

    @Test func driveMessageSaysWhatToDo() {
        #expect(
            Copy.needsFullDiskAccess(label: "2TB-SSD")
                == "Driveway's helper needs Full Disk Access to use 2TB-SSD. Open Setup to allow it.")
    }

    @Test func probeErrnoMapping() {
        #expect(FullDiskAccess.status(openErrno: 0) == true)
        #expect(FullDiskAccess.status(openErrno: EPERM) == false)
        #expect(FullDiskAccess.status(openErrno: EACCES) == false)
        #expect(FullDiskAccess.status(openErrno: ENOENT) == nil)
        #expect(FullDiskAccess.status(openErrno: EIO) == nil)
    }

    @Test func toolOutputThatSaysTheDeviceCouldNotBeOpened() {
        let denied = [
            "Error opening '/dev/disk8s1': Operation not permitted\nFailed to mount '/dev/disk8s1': Operation not permitted",
            "Error opening '/dev/disk8s1': Operation not permitted\nVolume is corrupt. You should run chkdsk.",
            "e2fsck 1.47.1 (20-May-2024)\ne2fsck: Operation not permitted while trying to open /dev/disk6s1",
            "mkfs.ext4: Operation not permitted while trying to determine filesystem size",
            "ERROR(1): Opening '/dev/disk8s1' as NTFS failed: Operation not permitted",
            "umount: unmount(/Volumes/Untitled 1): Operation not permitted",
        ]
        for output in denied { #expect(FullDiskAccess.deniedInToolOutput(output), "\(output)") }

        let other = [
            "", "fuse: device busy", "Volume is corrupt. You should run chkdsk.",
            "umount(/Volumes/LINUX): Resource busy -- try 'diskutil unmount'",
            "mount_macfuse: Operation not permitted",
        ]
        for output in other { #expect(!FullDiskAccess.deniedInToolOutput(output), "\(output)") }
    }
}

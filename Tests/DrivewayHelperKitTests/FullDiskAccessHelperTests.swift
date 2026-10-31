import DrivewayCore
import DrivewayHelperKit
import DrivewayIPC
import Foundation
import Testing

private let auth = Data([1, 2, 3])
/// What `DADiskInventory.header(of:)` throws when macOS privacy protection refuses the raw device.
private let refused = DADiskInventory.HeaderError.openFailed(EPERM)
private let backupNeedsAccess = Copy.needsFullDiskAccess(label: "BACKUP")
private let ntfsRefused = "Error opening '/dev/disk4s1': Operation not permitted\nFailed to mount '/dev/disk4s1': Operation not permitted\n"
private let ntfsfixRefused = "Error opening '/dev/disk4s1': Operation not permitted\nVolume is corrupt. You should run chkdsk.\n"

private func volumes(_ h: Harness) async -> [Volume] {
    if case .volumes(let v) = await h.service.handle(.listVolumes, authorization: nil) { return v }
    return []
}

private func leaveLog(_ h: Harness, _ bsd: String) -> String? {
    h.logs.value.first { $0.hasPrefix("Leaving \(bsd) to macOS: ") }
}

// MARK: - Plug-in

@Test func ntfsDriveTheHelperMayNotOpenIsReportedNotLeftSilently() async {
    let d = disk("disk4s1", name: "BACKUP")
    let h = makeHarness(disks: [d])
    h.inventory.setHeaderError(refused, for: "disk4s1")
    _ = await h.service.handle(.backendStatus, authorization: nil)
    _ = await h.service.handle(.listVolumes, authorization: nil)
    #expect(!h.service.shouldApproveMacOSMount(d))  // DiskArbitration's "ntfs" made Driveway claim it

    let event = await h.service.diskAppeared(d)
    guard case .mountFailed(let v, let message) = event else { Issue.record("expected .mountFailed, got \(String(describing: event))"); return }
    #expect(message == backupNeedsAccess)
    #expect(v.lastError == backupNeedsAccess)
    // No ntfs-3g: the drive goes back to macOS, read-only.
    #expect(h.runner.commands == [cmd(diskutil, "mount", "/dev/disk4s1")])
    #expect(h.service.shouldApproveMacOSMount(d))
    // The Info tab keeps saying why.
    #expect(await volumes(h).first { $0.bsdName == "disk4s1" }?.lastError == backupNeedsAccess)
    #expect(leaveLog(h, "disk4s1")?.contains("Full Disk Access") == true)
}

@Test func extDriveTheHelperMayNotOpenIsReportedAndListed() async {
    // macOS has no ext probe: without the header nothing says what the drive is.
    let d = disk("disk6s1", kind: nil, content: "Linux Filesystem", name: "LINUX")
    let h = makeHarness(disks: [d])
    h.inventory.setHeaderError(refused, for: "disk6s1")
    let message = Copy.needsFullDiskAccess(label: "LINUX")
    let event = await h.service.diskAppeared(d)
    guard case .mountFailed(let v, message) = event else { Issue.record("expected .mountFailed, got \(String(describing: event))"); return }
    #expect(v.bsdName == "disk6s1")
    #expect(v.lastError == message)
    #expect(h.runner.commands.isEmpty)
    #expect(await volumes(h).first { $0.bsdName == "disk6s1" }?.lastError == message)
}

@Test func refusedHeaderOnADriveDrivewayWouldNotMountStaysQuiet() async {
    let exfat = disk("disk5s1", kind: "exfat", name: "STICK")
    let h = makeHarness(disks: [exfat])
    h.inventory.setHeaderError(refused, for: "disk5s1")
    #expect(await h.service.diskAppeared(exfat) == nil)
    #expect(h.runner.commands.isEmpty)

    let ntfs = disk("disk4s1", name: "BACKUP")
    let off = makeHarness(disks: [ntfs], settings: DrivewaySettings(autoMountNTFS: false))
    off.inventory.setHeaderError(refused, for: "disk4s1")
    #expect(await off.service.diskAppeared(ntfs) == nil)
    #expect(off.runner.commands.isEmpty)
    #expect(leaveLog(off, "disk4s1")?.contains("auto-mount is off") == true)
}

@Test func ntfs3gRefusedTheDeviceIsFullDiskAccessNotCorrupt() async {
    let d = disk("disk4s1", name: "BACKUP")
    let h = makeHarness(disks: [d], headers: ["disk4s1": ntfsHeader])
    h.runner.script(tools.ntfs3g, "/dev/disk4s1", exit: 21, stderr: ntfsRefused)
    let event = await h.service.diskAppeared(d)
    guard case .mountFailed(let v, let message) = event else { Issue.record("expected .mountFailed, got \(String(describing: event))"); return }
    #expect(message == backupNeedsAccess)
    #expect(v.lastError == backupNeedsAccess)
    #expect(h.runner.commands.last == cmd(diskutil, "mount", "/dev/disk4s1"))
}

@Test func refusalIsTheToolsOwnWhenTheHelperHasFullDiskAccess() async {
    // With Full Disk Access granted, "Operation not permitted" means something else: report the tool's words.
    let d = disk("disk4s1", name: "BACKUP")
    let h = makeHarness(disks: [d], headers: ["disk4s1": ntfsHeader])
    h.inventory.setFullDiskAccess(true)
    h.runner.script(tools.ntfsfix, "-n", exit: 1, stderr: ntfsfixRefused)
    guard case .report(let r) = await h.service.handle(.check(ref("disk4s1")), authorization: nil) else {
        Issue.record("expected a report")
        return
    }
    #expect(!r.succeeded)
}

@Test func driveLeftForFullDiskAccessIsTakenOverOnceGranted() async {
    let d = disk("disk4s1", name: "BACKUP")
    let h = makeHarness(disks: [d])
    h.inventory.setHeaderError(refused, for: "disk4s1")
    guard case .mountFailed = await h.service.diskAppeared(d) else { Issue.record("expected .mountFailed"); return }
    h.inventory.setHeaderError(nil, for: "disk4s1")
    h.inventory.setHeader(ntfsHeader, for: "disk4s1")
    let events = await h.service.reevaluateDrives()
    guard case .mounted(let v)? = events.first else { Issue.record("expected .mounted, got \(events)"); return }
    #expect(v.lastError == nil)
    #expect(v.access == .readWrite)
}

// MARK: - Check, repair, backup, format, unmount

@Test func checkAndRepairWithoutFullDiskAccessSaySoNotCorrupt() async {
    let h = makeHarness(disks: [disk("disk4s1", name: "BACKUP")], headers: ["disk4s1": ntfsHeader])
    h.runner.script(tools.ntfsfix, "-n", exit: 1, stderr: ntfsfixRefused)
    h.runner.script(tools.ntfsfix, "-d", exit: 1, stderr: ntfsfixRefused)
    #expect(await h.service.handle(.check(ref("disk4s1")), authorization: nil) == .error(.commandFailed(backupNeedsAccess)))
    #expect(await h.service.handle(.repair(ref("disk4s1"), force: false), authorization: auth) == .error(.commandFailed(backupNeedsAccess)))
    #expect(await h.service.handle(.fixAndMount(ref("disk4s1")), authorization: auth) == .error(.commandFailed(backupNeedsAccess)))
}

@Test func extCheckWithoutFullDiskAccessSaysSo() async {
    let d = disk("disk6s1", kind: nil, content: "Linux Filesystem", name: "LINUX")
    let h = makeHarness(disks: [d], headers: ["disk6s1": ext4Header])
    h.runner.script(tools.e2fsck, "-n", exit: 8, stderr: "e2fsck: Operation not permitted while trying to open /dev/disk6s1\n")
    #expect(
        await h.service.handle(.check(ref("disk6s1")), authorization: nil)
            == .error(.commandFailed(Copy.needsFullDiskAccess(label: "LINUX"))))
}

@Test func backupWithoutFullDiskAccessSaysSo() async {
    let h = makeHarness(disks: [disk("disk4s1", name: "BACKUP")], headers: ["disk4s1": ntfsHeader])
    h.runner.script(tools.ntfsclone, "--save-image", exit: 1, stderr: "ERROR(1): Opening '/dev/disk4s1' as NTFS failed: Operation not permitted\n")
    #expect(
        await h.service.handle(.backup(ref("disk4s1"), imagePath: "/Users/x/b.img"), authorization: auth)
            == .error(.commandFailed(backupNeedsAccess)))
}

private let gpt4 = disk("disk4", wholeMedia: true, kind: nil, content: "GUID_partition_scheme", name: nil)
private let efi4 = disk("disk4s1", kind: "msdos", content: "EFI", name: "EFI", size: 209_715_200)

@Test func formatWithoutFullDiskAccessStopsBeforeErasing() async {
    let h = makeHarness(disks: [gpt4, efi4, disk("disk4s2", name: "BACKUP")])
    h.inventory.setFullDiskAccess(false)
    for fs in [FilesystemKind.ntfs, .ext4] {
        let r = FormatRequest(filesystem: fs, label: "NEW", scheme: .gpt, target: .partition("disk4s2"), confirmation: "BACKUP", expectedKey: "UUID-disk4s2")
        #expect(await h.service.handle(.format(r), authorization: auth) == .error(.commandFailed(backupNeedsAccess)))
    }
    #expect(h.runner.commands.isEmpty)
    // exFAT and FAT go through diskutil, which needs no Full Disk Access.
    let exfat = FormatRequest(filesystem: .exfat, label: "STICK", scheme: .gpt, target: .partition("disk4s2"), confirmation: "BACKUP", expectedKey: "UUID-disk4s2")
    #expect(await h.service.handle(.format(exfat), authorization: auth) == .ok)
}

@Test func mkntfsRefusedTheDeviceSaysFullDiskAccess() async {
    let h = makeHarness(disks: [gpt4, efi4, disk("disk4s2", name: "BACKUP")])
    h.runner.script(tools.mkntfs, "--quick", exit: 1, stderr: "Could not open '/dev/disk4s2': Operation not permitted\n")
    let r = FormatRequest(filesystem: .ntfs, label: "NEW", scheme: .gpt, target: .partition("disk4s2"), confirmation: "BACKUP", expectedKey: "UUID-disk4s2")
    #expect(await h.service.handle(.format(r), authorization: auth) == .error(.commandFailed(backupNeedsAccess)))
}

@Test func umountRefusedIsFullDiskAccess() async {
    let d = disk("disk6s1", kind: nil, content: "Linux Filesystem", name: "LINUX")
    let h = makeHarness(disks: [d], headers: ["disk6s1": ext4Header])
    _ = await h.service.diskAppeared(d)
    h.runner.script(diskutil, "unmount", exit: 1, stderr: "disk6s1 was already unmounted\n")
    h.runner.script(tools.umount, "/Volumes/LINUX", exit: 1, stderr: "umount: unmount(/Volumes/LINUX): Operation not permitted\n")
    h.runner.script(tools.umount, "-f", exit: 1, stderr: "umount: unmount(/Volumes/LINUX): Operation not permitted\n")
    h.inventory.setStuck(["/Volumes/LINUX"])
    #expect(
        await h.service.handle(.unmount(ref("disk6s1")), authorization: nil)
            == .error(.commandFailed(Copy.needsFullDiskAccess(label: "LINUX"))))
}

// MARK: - Every drive left to macOS is logged with the reason

@Test func everyDriveLeftToMacOSIsLoggedWithTheReason() async {
    let ntfs = disk("disk4s1", name: "BACKUP")
    func reason(
        _ d: DiskDescription = ntfs, headers: [String: Data] = ["disk4s1": ntfsHeader], probe: FakeProbe = .kernel,
        settings: DrivewaySettings = DrivewaySettings(), console: ConsoleUser? = ConsoleUser(uid: 501, gid: 20),
        features: [Feature: FeatureState] = allReady, boot: Set<String> = ["disk0"]
    ) async -> String? {
        let h = makeHarness(disks: [d], headers: headers, probe: probe, settings: settings, console: console, features: features, boot: boot)
        _ = await h.service.diskAppeared(d)
        return leaveLog(h, d.bsdName)
    }
    let boot = disk("disk0s2", kind: "apfs", content: "41504653-0000-11AA-AA11-00306543ECAC", name: "Macintosh HD")
    #expect(await reason(boot)?.contains("protected") == true)
    #expect(await reason(boot: [])?.contains("protected") == true)
    let unknown = await reason(disk("disk5s1", kind: nil, content: "Linux Filesystem", name: "X"), headers: [:])
    #expect(unknown?.contains("unknown filesystem") == true)
    #expect(unknown?.contains("header") == true)
    #expect(await reason(settings: DrivewaySettings(autoMountNTFS: false))?.contains("auto-mount is off") == true)
    #expect(await reason(settings: DrivewaySettings(alwaysReadOnly: [ntfs.settingsKey]))?.contains("always mount read-only") == true)
    var locked = allReady
    locked[.writeNTFS] = .locked(missing: [.ntfs3g])
    #expect(await reason(features: locked)?.contains("writeNTFS is not ready (locked: ntfs3g)") == true)
    #expect(await reason(console: nil)?.contains("nobody is logged in") == true)
    #expect(await reason(probe: .none)?.contains("backend is not ready (needsApproval(fskit))") == true)
}

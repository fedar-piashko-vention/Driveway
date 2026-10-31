import DrivewayCore
import DrivewayHelperKit
import DrivewayIPC
import Foundation
import Testing

private let auth = Data([1, 2, 3])
private let ntfs3g = tools.ntfs3g
private let unmount4s1 = cmd(diskutil, "unmount", "/dev/disk4s1")
private let ntfs3gBackup = cmd(ntfs3g, "/dev/disk4s1", "/Volumes/BACKUP", "-o", "volname=BACKUP,uid=501,gid=20,norecover")
private let ntfsfixOK = """
    Mounting volume... OK
    Processing of $MFT and $MFTMirr completed successfully.
    Checking the alternate boot sector... OK
    NTFS volume version is 3.1.
    NTFS partition /dev/disk4s1 was processed successfully.
    """

private func mountedVolume(_ r: HelperResponse) -> Volume? {
    if case .volume(let v) = r { return v }
    return nil
}

// MARK: - Safety

@Test func protectedDiskIsRefusedForEveryOperation() async {
    let disks = [
        disk("disk0", wholeMedia: true, kind: nil, content: "GUID_partition_scheme", name: nil),
        disk("disk0s1", kind: "ntfs", name: "BOOTNTFS", path: "/Volumes/BOOTNTFS"),
    ]
    let h = makeHarness(disks: disks, headers: ["disk0s1": ntfsHeader])
    let requests: [HelperRequest] = [
        .mount(ref("disk0s1")), .unmount(ref("disk0s1")), .eject(ref("disk0s1")), .fixAndMount(ref("disk0s1")), .check(ref("disk0s1")),
        .repair(ref("disk0s1"), force: false), .repair(ref("disk0s1"), force: true), .backup(ref("disk0s1"), imagePath: "/tmp/b.img"),
        .format(FormatRequest(filesystem: .ntfs, label: "X", scheme: .gpt, target: .partition("disk0s1"), confirmation: "BOOTNTFS", expectedKey: "UUID-disk0s1")),
        .format(FormatRequest(filesystem: .exfat, label: "X", scheme: .gpt, target: .wholeDisk("disk0"), confirmation: "BOOTNTFS", expectedKey: "UUID-disk0")),
    ]
    for r in requests {
        #expect(await h.service.handle(r, authorization: auth) == .error(.protectedDisk), "\(r)")
    }
    #expect(await h.service.diskAppeared(disks[1]) == nil)
    #expect(h.service.shouldApproveMacOSMount(disks[1]))
    #expect(await h.service.handle(.listVolumes, authorization: nil) == .volumes([]))
    #expect(h.runner.commands.isEmpty)
    #expect(h.inventory.headerReads.isEmpty)
}

@Test func failsClosedWithoutBootDisks() async {
    let d = disk("disk4s1", path: "/Volumes/BACKUP")
    let h = makeHarness(disks: [d, disk("disk4", wholeMedia: true, kind: nil, content: "GUID_partition_scheme", name: nil)],
                        headers: ["disk4s1": ntfsHeader], boot: [])
    let requests: [HelperRequest] = [
        .mount(ref("disk4s1")), .unmount(ref("disk4s1")), .eject(ref("disk4s1")), .fixAndMount(ref("disk4s1")), .check(ref("disk4s1")),
        .repair(ref("disk4s1"), force: false), .backup(ref("disk4s1"), imagePath: "/tmp/b.img"),
        .format(FormatRequest(filesystem: .ntfs, label: "NEW", scheme: .gpt, target: .wholeDisk("disk4"), confirmation: "BACKUP", expectedKey: "UUID-disk4")),
    ]
    for r in requests {
        #expect(await h.service.handle(r, authorization: auth) == .error(.protectedDisk), "\(r)")
    }
    #expect(await h.service.handle(.listVolumes, authorization: nil) == .volumes([]))
    #expect(await h.service.diskAppeared(d) == nil)
    _ = await h.service.handle(.backendStatus, authorization: nil)
    #expect(h.service.shouldApproveMacOSMount(d))
    #expect(h.runner.commands.isEmpty)
}

@Test func invalidBSDNamesAreRejectedBeforeAnyLookup() async {
    let weird = ["disk4s1; rm -rf /", "../disk4s1", "disk٤s1", "disk4s", "rdisk4s1", "disk4s1s2", "", "disk", "/dev/disk4s1", "disk4s1\n"]
    // Even a disk whose (bogus) name is listed by the inventory is not touched.
    let h = makeHarness(disks: weird.map { disk($0, whole: "disk4") } + [disk("disk4s1")])
    for name in weird {
        for r: HelperRequest in [.mount(ref(name)), .unmount(ref(name)), .eject(ref(name)), .check(ref(name)), .repair(ref(name), force: false),
                                 .fixAndMount(ref(name)), .backup(ref(name), imagePath: "/tmp/b.img")] {
            #expect(await h.service.handle(r, authorization: auth) == .error(.unknownVolume), "\(r)")
        }
        let format = FormatRequest(filesystem: .ntfs, label: "NEW", scheme: .gpt, target: .partition(name), confirmation: "BACKUP", expectedKey: "UUID-\(name)")
        #expect(await h.service.handle(.format(format), authorization: auth) == .error(.unknownVolume))
        #expect(await h.service.diskAppeared(disk(name, whole: "disk4")) == nil)
    }
    #expect(h.runner.commands.isEmpty)
    #expect(h.inventory.headerReads.isEmpty)
}

@Test func destructiveWithoutAuthorizationIsRefused() async {
    let h = makeHarness(disks: [disk("disk4", wholeMedia: true, kind: nil, content: "GUID_partition_scheme", name: nil),
                                disk("disk4s1", path: "/Volumes/BACKUP")],
                        headers: ["disk4s1": ntfsHeader], auth: false)
    let requests: [HelperRequest] = [
        .repair(ref("disk4s1"), force: false), .fixAndMount(ref("disk4s1")), .backup(ref("disk4s1"), imagePath: "/tmp/b.img"),
        .format(FormatRequest(filesystem: .ntfs, label: "NEW", scheme: .gpt, target: .wholeDisk("disk4"), confirmation: "BACKUP", expectedKey: "UUID-disk4")),
    ]
    for r in requests {
        #expect(await h.service.handle(r, authorization: auth) == .error(.notAuthorized), "\(r)")
        #expect(await h.service.handle(r, authorization: nil) == .error(.notAuthorized), "\(r)")
    }
    #expect(h.runner.commands.isEmpty)
}

// MARK: - Mounting

@Test func mountRunsExactNtfs3gCommand() async {
    let h = makeHarness(disks: [disk("disk4s1", name: "BACKUP", path: "/Volumes/BACKUP")], headers: ["disk4s1": ntfsHeader])
    let response = await h.service.handle(.mount(ref("disk4s1")), authorization: nil)
    #expect(h.runner.commands == [unmount4s1, ntfs3gBackup])
    let v = mountedVolume(response)
    #expect(v?.access == .readWrite)
    #expect(v?.mountedBy == .driveway)
    #expect(v?.mountPoint == "/Volumes/BACKUP")
    #expect(v?.backend == .kernel)
    #expect(v?.filesystem == .ntfs)
    #expect(h.inventory.mountChecks == ["/Volumes/BACKUP"])
}

@Test func mountIsIdempotent() async {
    let d = disk("disk4s1", path: "/Volumes/BACKUP")
    let h = makeHarness(disks: [d], headers: ["disk4s1": ntfsHeader])
    let first = await h.service.handle(.mount(ref("disk4s1")), authorization: nil)
    let count = h.runner.commands.count
    let v = mountedVolume(first)
    #expect(v?.mountedBy == .driveway)

    #expect(await h.service.handle(.mount(ref("disk4s1")), authorization: nil) == .volume(v))
    #expect(await h.service.diskAppeared(d) == .mounted(v!))
    #expect(h.runner.commands.count == count)
}

@Test func headerDetectionWinsOverDiskArbitrationKind() async {
    // The spike saw DiskArbitration report a fresh NTFS partition as "exfat".
    let d = disk("disk4s1", kind: "exfat", name: "BACKUP", path: nil)
    let h = makeHarness(disks: [d], headers: ["disk4s1": ntfsHeader])
    let event = await h.service.diskAppeared(d)
    #expect(h.runner.commands == [ntfs3gBackup])
    if case .mounted(let v) = event { #expect(v.filesystem == .ntfs) } else { Issue.record("expected .mounted, got \(String(describing: event))") }
    #expect(!h.service.shouldApproveMacOSMount(d))
}

@Test func unreadableHeaderFallsBackToDiskArbitrationKind() async {
    let exfat = disk("disk4s1", kind: "exfat", name: "STICK")
    let h = makeHarness(disks: [exfat])  // no header: read throws
    #expect(await h.service.diskAppeared(exfat) == nil)
    #expect(h.runner.commands.isEmpty)
    #expect(h.inventory.headerReads == ["disk4s1"])

    let ntfs = disk("disk5s1", kind: "ntfs", name: "BACKUP")
    let h2 = makeHarness(disks: [ntfs])
    let event = await h2.service.diskAppeared(ntfs)
    #expect(h2.runner.commands == [cmd(ntfs3g, "/dev/disk5s1", "/Volumes/BACKUP", "-o", "volname=BACKUP,uid=501,gid=20,norecover")])
    if case .mounted = event {} else { Issue.record("expected .mounted") }
}

@Test func extMountsReadOnlyWithExt4fuse() async {
    let d = disk("disk6s1", kind: nil, content: "Linux Filesystem", name: "LINUX")
    let h = makeHarness(disks: [d], headers: ["disk6s1": ext4Header], probe: .fskit)
    let event = await h.service.diskAppeared(d)
    #expect(h.runner.commands == [cmd(tools.ext4fuse, "/dev/disk6s1", "/Volumes/LINUX", "-o", "backend=fskit,volname=LINUX")])
    guard case .mounted(let v) = event else { Issue.record("expected .mounted"); return }
    #expect(v.filesystem == .ext4)
    #expect(v.access == .readOnly)
    #expect(v.backend == .fskit)
}

@Test func fskitMountMustAppear() async {
    let d = disk("disk4s1", name: "BACKUP")
    let h = makeHarness(disks: [d], headers: ["disk4s1": ntfsHeader], probe: .fskit, mounted: false)
    let event = await h.service.diskAppeared(d)
    guard case .mountFailed(let v, _) = event else { Issue.record("expected .mountFailed, got \(String(describing: event))"); return }
    #expect(v.bsdName == "disk4s1")
    #expect(h.runner.commands == [
        cmd(ntfs3g, "/dev/disk4s1", "/Volumes/BACKUP", "-o", "backend=fskit,volname=BACKUP,uid=501,gid=20,norecover"),
        cmd(diskutil, "mount", "/dev/disk4s1"),
    ])
    #expect(h.settings.current.fskitFailedOnOSBuild == osBuild)
    #expect(h.service.shouldApproveMacOSMount(d))
    #expect(await h.service.handle(.backendStatus, authorization: nil) == .backend(.unavailable))

    // The next appearance on the same OS build leaves the drive to macOS.
    let before = h.runner.commands.count
    _ = await h.service.diskDisappeared("disk4s1")
    #expect(await h.service.diskAppeared(d) == nil)
    #expect(h.runner.commands.count == before)
}

@Test func extFskitMountMustAppear() async {
    let d = disk("disk6s1", kind: nil, content: "Linux Filesystem", name: "LINUX")
    let h = makeHarness(disks: [d], headers: ["disk6s1": ext4Header], probe: .fskit, mounted: false)
    guard case .mountFailed = await h.service.diskAppeared(d) else { Issue.record("expected .mountFailed"); return }
    #expect(h.runner.commands.last == cmd(diskutil, "mount", "/dev/disk6s1"))
    #expect(h.settings.current.fskitFailedOnOSBuild == osBuild)
    #expect(h.service.shouldApproveMacOSMount(d))
}

@Test func kernelMountMustAppearToo() async {
    let d = disk("disk4s1", name: "BACKUP")
    let h = makeHarness(disks: [d], headers: ["disk4s1": ntfsHeader], probe: .kernel, mounted: false)
    let response = await h.service.handle(.mount(ref("disk4s1")), authorization: nil)
    guard case .error(.commandFailed) = response else { Issue.record("expected commandFailed, got \(response)"); return }
    #expect(h.runner.commands.last == cmd(diskutil, "mount", "/dev/disk4s1"))
    #expect(h.settings.current.fskitFailedOnOSBuild == nil)
    #expect(h.service.shouldApproveMacOSMount(d))
}

@Test func fskitFailureOnAnotherBuildDoesNotBlock() async {
    let h = makeHarness(disks: [], probe: .fskit, settings: DrivewaySettings(fskitFailedOnOSBuild: "23A344"))
    #expect(await h.service.handle(.backendStatus, authorization: nil) == .backend(.ready(.fskit)))
    let h2 = makeHarness(disks: [], probe: .none)
    #expect(await h2.service.handle(.backendStatus, authorization: nil) == .backend(.needsApproval(.fskit)))
    let h3 = makeHarness(disks: [], probe: FakeProbe(kextsAllowed: true, kextApproved: false, fskitEnabled: true))
    #expect(await h3.service.handle(.backendStatus, authorization: nil) == .backend(.needsApproval(.kernel)))
}

@Test func noBackendLeavesDriveToMacOS() async {
    let d = disk("disk4s1", name: "BACKUP")
    for (probe, settings) in [(FakeProbe.fskit, DrivewaySettings(fskitFailedOnOSBuild: osBuild)), (.none, DrivewaySettings())] {
        let h = makeHarness(disks: [d], headers: ["disk4s1": ntfsHeader], probe: probe, settings: settings)
        #expect(await h.service.diskAppeared(d) == nil)
        #expect(h.runner.commands.isEmpty)
        #expect(h.service.shouldApproveMacOSMount(d))
    }
}

@Test func noConsoleUserLeavesNTFSToMacOS() async {
    let d = disk("disk4s1", name: "BACKUP")
    for console in [ConsoleUser(uid: 0, gid: 0), nil] {
        let h = makeHarness(disks: [d], headers: ["disk4s1": ntfsHeader], console: console)
        #expect(await h.service.diskAppeared(d) == nil)
        #expect(h.runner.commands.isEmpty)
        #expect(h.service.shouldApproveMacOSMount(d))
    }
}

@Test func dirtyMountFallsBackToReadOnly() async {
    let d = disk("disk4s1", name: "BACKUP")
    let h = makeHarness(disks: [d], headers: ["disk4s1": ntfsHeader])
    h.runner.script(ntfs3g, "/dev/disk4s1", exit: 15)
    let event = await h.service.diskAppeared(d)
    guard case .mountedReadOnly(let v, let reason) = event else { Issue.record("expected .mountedReadOnly, got \(String(describing: event))"); return }
    #expect(reason == .dirty)
    #expect(v.health == .dirty)
    #expect(v.access == .readOnly)
    #expect(v.mountedBy == .macOS)
    #expect(h.runner.commands.last == cmd(diskutil, "mount", "/dev/disk4s1"))
    #expect(h.service.shouldApproveMacOSMount(d))
}

@Test func hibernatedAndOtherFailuresFallBackToReadOnly() async {
    let d = disk("disk4s1", name: "BACKUP")
    let h = makeHarness(disks: [d], headers: ["disk4s1": ntfsHeader])
    h.runner.script(ntfs3g, "/dev/disk4s1", exit: 14)
    guard case .mountedReadOnly(let v, .hibernated) = await h.service.diskAppeared(d) else { Issue.record("expected hibernated"); return }
    #expect(v.health == .hibernated)

    let h2 = makeHarness(disks: [d], headers: ["disk4s1": ntfsHeader])
    h2.runner.script(ntfs3g, "/dev/disk4s1", exit: 1, stderr: "fuse: device busy\n")
    guard case .mountedReadOnly(let v2, .error(let message)) = await h2.service.diskAppeared(d) else { Issue.record("expected error reason"); return }
    #expect(message == "fuse: device busy")
    #expect(v2.lastError == "fuse: device busy")
    #expect(h2.runner.commands.last == cmd(diskutil, "mount", "/dev/disk4s1"))
}

@Test func backedOffWhenOtherDriverOwnsVolume() async {
    let d = disk("disk4s1", kind: "tuxera_ntfs", name: "BACKUP", path: "/Volumes/BACKUP")
    let h = makeHarness(disks: [d], headers: ["disk4s1": ntfsHeader])
    let event = await h.service.diskAppeared(d)
    guard case .backedOff(let v, let driver) = event else { Issue.record("expected .backedOff"); return }
    #expect(driver == "Tuxera NTFS")
    #expect(v.mountedBy == .otherDriver("Tuxera NTFS"))
    #expect(h.runner.commands.isEmpty)
}

@Test func approvesMacOSMountOnlyWhenNotTakingOver() async {
    let ntfs = disk("disk4s1", name: "BACKUP")
    let exfat = disk("disk5s1", kind: "exfat", name: "STICK")
    let boot = disk("disk0s2", kind: "apfs", content: "41504653-0000-11AA-AA11-00306543ECAC", name: "Macintosh HD")
    let readOnly = disk("disk7s1", name: "RO")
    let h = makeHarness(disks: [ntfs, exfat, boot, readOnly], settings: DrivewaySettings(alwaysReadOnly: [readOnly.settingsKey]))
    // Nothing known yet (boot disks, backend): never block macOS.
    #expect(h.service.shouldApproveMacOSMount(ntfs))

    _ = await h.service.handle(.backendStatus, authorization: nil)
    _ = await h.service.handle(.listVolumes, authorization: nil)
    #expect(!h.service.shouldApproveMacOSMount(ntfs))
    #expect(h.service.shouldApproveMacOSMount(exfat))
    #expect(h.service.shouldApproveMacOSMount(boot))
    #expect(h.service.shouldApproveMacOSMount(readOnly))
    #expect(h.service.shouldApproveMacOSMount(disk("disk4s1; x")))
    #expect(h.runner.commands.isEmpty)
}

@Test func blockedMountIsHandedBackWhenNotTakingOver() async {
    // The approval callback blocked macOS, but by the time the disk is processed the user has logged out.
    let d = disk("disk4s1", name: "BACKUP")
    let console = ConsoleBox(ConsoleUser(uid: 501, gid: 20))
    let h = makeHarness(disks: [d], headers: ["disk4s1": ntfsHeader], consoleProvider: { console.value })
    _ = await h.service.handle(.backendStatus, authorization: nil)
    _ = await h.service.handle(.listVolumes, authorization: nil)
    #expect(!h.service.shouldApproveMacOSMount(d))

    console.value = nil
    #expect(await h.service.diskAppeared(d) == nil)
    #expect(h.runner.commands == [cmd(diskutil, "mount", "/dev/disk4s1")])
    #expect(h.service.shouldApproveMacOSMount(d))
}

// MARK: - Unmount, eject, disappear

@Test func unmountAndEjectUseDiskutil() async {
    let h = makeHarness(disks: [disk("disk4s1", path: "/Volumes/BACKUP")], headers: ["disk4s1": ntfsHeader])
    _ = await h.service.handle(.mount(ref("disk4s1")), authorization: nil)
    #expect(await h.service.handle(.unmount(ref("disk4s1")), authorization: nil) == .ok)
    #expect(await h.service.handle(.eject(ref("disk4s1")), authorization: nil) == .ok)
    #expect(Array(h.runner.commands.suffix(2)) == [unmount4s1, cmd(diskutil, "eject", "/dev/disk4")])
    #expect(!h.runner.commands.contains { $0.executable == tools.umount })
}

@Test func disappearedDiskIsForgotten() async {
    let d = disk("disk4s1", path: "/Volumes/BACKUP")
    let h = makeHarness(disks: [d], headers: ["disk4s1": ntfsHeader])
    _ = await h.service.handle(.mount(ref("disk4s1")), authorization: nil)
    #expect(await h.service.diskDisappeared("disk4s1") == .removed(bsdName: "disk4s1"))
    let before = h.runner.commands.count
    _ = await h.service.handle(.mount(ref("disk4s1")), authorization: nil)
    #expect(h.runner.commands.count > before)  // no stale "already mounted" answer
}

@Test func vanishedDiskReturnsUnknownVolume() async {
    let h = makeHarness(disks: [disk("disk4s1")])
    #expect(await h.service.handle(.check(ref("disk9s1")), authorization: nil) == .error(.unknownVolume))
    #expect(await h.service.handle(.mount(ref("disk9s1")), authorization: nil) == .error(.unknownVolume))
    #expect(h.runner.commands.isEmpty)
}

@Test func missingToolIsReported() async {
    let h = makeHarness(disks: [disk("disk4s1")], headers: ["disk4s1": ntfsHeader])
    h.runner.fail(ntfs3g, "/dev/disk4s1", with: CommandRunnerError.toolMissing(ntfs3g))
    #expect(await h.service.handle(.mount(ref("disk4s1")), authorization: nil) == .error(.toolMissing(ntfs3g)))
}

// MARK: - Check, repair, fix

@Test func fixAndMountRunsNtfsfixThenMounts() async {
    let d = disk("disk4s1", name: "BACKUP", path: "/Volumes/BACKUP")
    let h = makeHarness(disks: [d], headers: ["disk4s1": ntfsHeader])
    h.runner.script(tools.ntfsfix, "-d", exit: 0, stdout: ntfsfixOK)
    let response = await h.service.handle(.fixAndMount(ref("disk4s1")), authorization: auth)
    #expect(h.runner.commands == [unmount4s1, cmd(tools.ntfsfix, "-d", "/dev/disk4s1"), ntfs3gBackup])
    #expect(mountedVolume(response)?.access == .readWrite)
}

@Test func checkUnmountsRunsDryRunAndRemounts() async {
    let h = makeHarness(disks: [disk("disk4s1", name: "BACKUP", path: "/Volumes/BACKUP")], headers: ["disk4s1": ntfsHeader])
    h.runner.script(tools.ntfsfix, "-n", exit: 0, stdout: ntfsfixOK)
    let response = await h.service.handle(.check(ref("disk4s1")), authorization: nil)
    #expect(h.runner.commands == [unmount4s1, cmd(tools.ntfsfix, "-n", "/dev/disk4s1"), ntfs3gBackup])
    guard case .report(let r) = response else { Issue.record("expected report"); return }
    #expect(r.succeeded == NTFSFixReport.parse(ntfsfixOK).succeeded)
    #expect(r.succeeded)
    #expect(r.mode == .check)
    #expect(r.filesystem == .ntfs)
    #expect(r.rawOutput.contains("processed successfully"))
}

@Test func extRepairUsesE2fsckModes() async {
    let d = disk("disk6s1", kind: nil, content: "Linux Filesystem", name: "LINUX")
    let h = makeHarness(disks: [d], headers: ["disk6s1": ext4Header])
    h.runner.script(tools.e2fsck, "-y", exit: 1)
    let first = await h.service.handle(.repair(ref("disk6s1"), force: false), authorization: auth)
    guard case .report(let plain) = first else { Issue.record("expected report, got \(first)"); return }
    #expect(plain.mode == .repair)
    #expect(plain.filesystem == .ext4)
    #expect(plain.succeeded)  // exit 0: clean
    #expect(plain.summary == "No problems found.")
    let forced = await h.service.handle(.repair(ref("disk6s1"), force: true), authorization: auth)
    #expect(h.runner.commands == [cmd(tools.e2fsck, "-p", "-f", "/dev/disk6s1"), cmd(tools.e2fsck, "-y", "-f", "/dev/disk6s1")])
    guard case .report(let r) = forced else { Issue.record("expected report"); return }
    #expect(r.mode == .repairForce)
    #expect(r.succeeded)  // exit 1: errors corrected
}

@Test func exfatCheckUsesDiskutilWithoutUnmounting() async {
    let h = makeHarness(disks: [disk("disk5s1", kind: "exfat", name: "STICK", path: "/Volumes/STICK")])
    h.runner.script(diskutil, "repairVolume", exit: 1, stderr: "bad")
    let check = await h.service.handle(.check(ref("disk5s1")), authorization: nil)
    let repair = await h.service.handle(.repair(ref("disk5s1"), force: false), authorization: auth)
    #expect(h.runner.commands == [cmd(diskutil, "verifyVolume", "/dev/disk5s1"), cmd(diskutil, "repairVolume", "/dev/disk5s1")])
    if case .report(let r) = check { #expect(r.succeeded && r.filesystem == .exfat) } else { Issue.record("expected report") }
    if case .report(let r) = repair { #expect(!r.succeeded) } else { Issue.record("expected report") }
}

@Test func backupRunsNtfscloneWithAbsolutePathOnly() async {
    let h = makeHarness(disks: [disk("disk4s1", name: "BACKUP")], headers: ["disk4s1": ntfsHeader])
    #expect(await h.service.handle(.backup(ref("disk4s1"), imagePath: "relative.img"), authorization: auth) == .error(.commandFailed("Choose a file location for the backup image.")))
    #expect(await h.service.handle(.backup(ref("disk4s1"), imagePath: "/dev/disk2"), authorization: auth) == .error(.commandFailed("Choose a file location for the backup image.")))
    #expect(h.runner.commands.isEmpty)
    #expect(await h.service.handle(.backup(ref("disk4s1"), imagePath: "/Users/x/b.img"), authorization: auth) == .ok)
    #expect(h.runner.commands == [cmd(tools.ntfsclone, "--save-image", "--force", "--output", "/Users/x/b.img", "/dev/disk4s1")])
}

// MARK: - Format

private let gptDisk4 = disk("disk4", wholeMedia: true, kind: nil, content: "GUID_partition_scheme", name: nil, size: 620_000_000_000)
private let efi4 = disk("disk4s1", kind: "msdos", content: "EFI", name: "EFI", size: 209_715_200)

@Test func formatValidatesBeforeRunning() async {
    let h = makeHarness(disks: [gptDisk4, efi4, disk("disk4s2", name: "BACKUP")])
    let r = FormatRequest(filesystem: .ntfs, label: "NEW", scheme: .gpt, target: .wholeDisk("disk4"), confirmation: "backup", expectedKey: "UUID-disk4")
    #expect(await h.service.handle(.format(r), authorization: auth) == .error(.validation(.confirmationMismatch)))
    // Typing the EFI partition's name doesn't confirm erasing the disk.
    let efiName = FormatRequest(filesystem: .ntfs, label: "NEW", scheme: .gpt, target: .wholeDisk("disk4"), confirmation: "EFI", expectedKey: "UUID-disk4")
    #expect(await h.service.handle(.format(efiName), authorization: auth) == .error(.validation(.confirmationMismatch)))
    let shape = FormatRequest(filesystem: .ntfs, label: "NEW", scheme: .gpt, target: .wholeDisk("disk4s2"), confirmation: "BACKUP", expectedKey: "UUID-disk4s2")
    #expect(await h.service.handle(.format(shape), authorization: auth) == .error(.validation(.invalidTarget)))
    #expect(h.runner.commands.isEmpty)
}

@Test func formatWholeDiskNTFSRunsPlanOnFreshDataPartition() async {
    // Before the erase the data is on disk4s1 (an MBR disk); afterwards GPT puts EFI on disk4s1 and the data on disk4s2.
    let mbrDisk4 = disk("disk4", wholeMedia: true, kind: nil, content: "FDisk_partition_scheme", name: nil)
    let h = makeHarness(disks: [mbrDisk4, disk("disk4s1", name: "BACKUP", path: "/Volumes/BACKUP")])
    let after = [gptDisk4, efi4, disk("disk4s2", kind: "exfat", name: "DRIVEWAYTMP", path: "/Volumes/DRIVEWAYTMP")]
    let inventory = h.inventory
    h.runner.onRun { if $0.arguments.first == "eraseDisk" { inventory.setDisks(after) } }
    let r = FormatRequest(filesystem: .ntfs, label: "NEW", scheme: .gpt, target: .wholeDisk("disk4"), confirmation: "BACKUP", expectedKey: "UUID-disk4")
    let response = await h.service.handle(.format(r), authorization: auth)
    #expect(h.runner.commands == [
        cmd(diskutil, "eraseDisk", "ExFAT", "DRIVEWAYTMP", "GPT", "/dev/disk4"),
        cmd(diskutil, "unmount", "/dev/disk4s2"),
        cmd(tools.mkntfs, "--quick", "--label", "NEW", "/dev/disk4s2"),
        cmd(ntfs3g, "/dev/disk4s2", "/Volumes/NEW", "-o", "volname=NEW,uid=501,gid=20,norecover"),
    ])
    let v = mountedVolume(response)
    #expect(v?.label == "NEW")
    #expect(v?.mountedBy == .driveway)
}

@Test func formatExfatPartitionRunsOnlyDiskutil() async {
    let h = makeHarness(disks: [gptDisk4, efi4, disk("disk4s2", name: "BACKUP")])
    let r = FormatRequest(filesystem: .exfat, label: "STICK", scheme: .gpt, target: .partition("disk4s2"), confirmation: "BACKUP", expectedKey: "UUID-disk4s2")
    #expect(await h.service.handle(.format(r), authorization: auth) == .ok)
    #expect(h.runner.commands == [cmd(diskutil, "eraseVolume", "ExFAT", "STICK", "/dev/disk4s2")])
}

@Test func formatStopsWhenFreshListShowsEFITarget() async {
    let h = makeHarness(disks: [gptDisk4, efi4, disk("disk4s2", name: "BACKUP")])
    let inventory = h.inventory
    let efiNow = disk("disk4s2", kind: "msdos", content: "c12a7328-f81f-11d2-ba4b-00a0c93ec93b", name: "EFI")
    h.runner.onRun { if $0.arguments.first == "eraseVolume" { inventory.setDisks([gptDisk4, efi4, efiNow]) } }
    let r = FormatRequest(filesystem: .ntfs, label: "NEW", scheme: .gpt, target: .partition("disk4s2"), confirmation: "BACKUP", expectedKey: "UUID-disk4s2")
    guard case .error(.commandFailed) = await h.service.handle(.format(r), authorization: auth) else { Issue.record("expected commandFailed"); return }
    #expect(h.runner.commands == [cmd(diskutil, "eraseVolume", "ExFAT", "DRIVEWAYTMP", "/dev/disk4s2")])
    #expect(!h.runner.commands.contains { $0.executable == tools.mkntfs })
}

@Test func formatStopsWhenFreshListHasNoDataPartitionOrTarget() async {
    let h = makeHarness(disks: [gptDisk4, efi4, disk("disk4s2", name: "BACKUP")])
    let inventory = h.inventory
    h.runner.onRun { if $0.arguments.first == "eraseDisk" { inventory.setDisks([gptDisk4, efi4]) } }
    let r = FormatRequest(filesystem: .ext4, label: "NEW", scheme: .gpt, target: .wholeDisk("disk4"), confirmation: "BACKUP", expectedKey: "UUID-disk4")
    guard case .error(.commandFailed) = await h.service.handle(.format(r), authorization: auth) else { Issue.record("expected commandFailed"); return }
    #expect(h.runner.commands.count == 1)

    let h2 = makeHarness(disks: [gptDisk4, efi4, disk("disk4s2", name: "BACKUP")])
    let inventory2 = h2.inventory
    h2.runner.onRun { if $0.arguments.first == "eraseVolume" { inventory2.setDisks([gptDisk4, efi4]) } }
    let r2 = FormatRequest(filesystem: .ntfs, label: "NEW", scheme: .gpt, target: .partition("disk4s2"), confirmation: "BACKUP", expectedKey: "UUID-disk4s2")
    guard case .error(.commandFailed) = await h2.service.handle(.format(r2), authorization: auth) else { Issue.record("expected commandFailed"); return }
    #expect(h2.runner.commands.count == 1)
}

@Test func failedToolReportsCommandFailed() async {
    let h = makeHarness(disks: [gptDisk4, efi4, disk("disk4s2", name: "BACKUP")])
    let inventory = h.inventory
    let after = [gptDisk4, efi4, disk("disk4s2", kind: "exfat", name: "DRIVEWAYTMP", path: "/Volumes/DRIVEWAYTMP")]
    h.runner.onRun { if $0.arguments.first == "eraseDisk" { inventory.setDisks(after) } }
    h.runner.script(tools.mkntfs, "--quick", exit: 1, stderr: "boom")
    let r = FormatRequest(filesystem: .ntfs, label: "NEW", scheme: .gpt, target: .wholeDisk("disk4"), confirmation: "BACKUP", expectedKey: "UUID-disk4")
    #expect(await h.service.handle(.format(r), authorization: auth) == .error(.commandFailed("boom")))
    #expect(h.runner.commands.last?.executable == tools.mkntfs)  // nothing mounted after the failure
}

// MARK: - Settings, version, listing

@Test func settingsVersionAndListing() async {
    let h = makeHarness(
        disks: [gptDisk4, efi4, disk("disk4s2", name: "BACKUP", path: "/Volumes/BACKUP"),
                disk("disk0s2", kind: "apfs", content: "41504653-0000-11AA-AA11-00306543ECAC", name: "Macintosh HD")],
        headers: ["disk4s2": ntfsHeader],
        settings: DrivewaySettings(fskitFailedOnOSBuild: osBuild))
    #expect(await h.service.handle(.helperVersion, authorization: nil) == .version(helperProtocolVersion))
    #expect(await h.service.handle(.getSettings, authorization: nil) == .settings(DrivewaySettings(fskitFailedOnOSBuild: osBuild)))

    // The app can't clear the helper's own FSKit record.
    #expect(await h.service.handle(.setSettings(DrivewaySettings(autoMountNTFS: false)), authorization: nil) == .ok)
    #expect(h.settings.current == DrivewaySettings(autoMountNTFS: false, fskitFailedOnOSBuild: osBuild))

    guard case .volumes(let list) = await h.service.handle(.listVolumes, authorization: nil) else { Issue.record("expected volumes"); return }
    #expect(list.map(\.bsdName) == ["disk4s2"])
    #expect(list.first?.mountedBy == .macOS)
    #expect(list.first?.access == .readOnly)
    #expect(list.first?.usedBytes == 1_000)
}

// MARK: - Review round 1: queueing, stale state, surfaced failures, settings

@Test func concurrentAppearancesOnOneDiskBothMount() async {
    let d1 = disk("disk4s1", name: "ONE")
    let d2 = disk("disk4s2", name: "TWO")
    let h = makeHarness(disks: [d1, d2], headers: ["disk4s1": ntfsHeader, "disk4s2": ntfsHeader])
    let gate = h.runner.hold(ntfs3g, "/dev/disk4s1")
    let service = h.service
    async let first = service.diskAppeared(d1)
    await gate.reached.wait()
    async let second = service.diskAppeared(d2)
    for _ in 0..<200 { await Task.yield() }
    #expect(!h.runner.commands.contains { $0.arguments.first == "/dev/disk4s2" })  // waiting, not dropped
    gate.open()
    let (e1, e2) = await (first, second)
    guard case .mounted(let v1) = e1, case .mounted(let v2) = e2 else {
        Issue.record("expected both mounted, got \(String(describing: e1)) and \(String(describing: e2))")
        return
    }
    #expect(v1.mountPoint == "/Volumes/ONE")
    #expect(v2.mountPoint == "/Volumes/TWO")
    #expect(h.runner.commands.map(\.executable) == [ntfs3g, ntfs3g])
}

@Test func requestDuringAutoMountWaitsThenRuns() async {
    let d = disk("disk4s1", name: "BACKUP")
    let h = makeHarness(disks: [d], headers: ["disk4s1": ntfsHeader])
    let gate = h.runner.hold(ntfs3g, "/dev/disk4s1")
    let service = h.service
    async let appeared = service.diskAppeared(d)
    await gate.reached.wait()
    async let unmounted = service.handle(.unmount(ref("disk4s1")), authorization: nil)
    for _ in 0..<200 { await Task.yield() }
    #expect(!h.runner.commands.contains(unmount4s1))
    gate.open()
    let (event, response) = await (appeared, unmounted)
    if case .mounted = event {} else { Issue.record("expected .mounted, got \(String(describing: event))") }
    #expect(response == .ok)
    #expect(h.runner.commands == [cmd(ntfs3g, "/dev/disk4s1", "/Volumes/BACKUP", "-o", "volname=BACKUP,uid=501,gid=20,norecover"), unmount4s1])
}

@Test func formatClearsStaleDetectionSoMacOSCanMountDuringErase() async {
    let h = makeHarness(disks: [gptDisk4, efi4, disk("disk4s2", name: "BACKUP")], headers: ["disk4s2": ntfsHeader])
    _ = await h.service.handle(.backendStatus, authorization: nil)
    _ = await h.service.handle(.listVolumes, authorization: nil)  // remembers disk4s2 as NTFS
    let temporary = disk("disk4s2", kind: "exfat", name: "DRIVEWAYTMP")
    #expect(!h.service.shouldApproveMacOSMount(temporary))  // the stale NTFS detection would refuse macOS

    let service = h.service
    let inventory = h.inventory
    let duringErase = Box<[Bool]>([])
    let after = [gptDisk4, efi4, disk("disk4s2", kind: "exfat", name: "DRIVEWAYTMP", path: "/Volumes/DRIVEWAYTMP")]
    h.runner.onRun { c in
        guard c.arguments.first == "eraseDisk" else { return }
        duringErase.value = [service.shouldApproveMacOSMount(temporary),
                             service.shouldApproveMacOSMount(disk("disk4s3", kind: "exfat", name: "NEW"))]
        inventory.setDisks(after)
    }
    let r = FormatRequest(filesystem: .ntfs, label: "NEW", scheme: .gpt, target: .wholeDisk("disk4"), confirmation: "BACKUP", expectedKey: "UUID-disk4")
    _ = await h.service.handle(.format(r), authorization: auth)
    #expect(duringErase.value == [true, true])
}

@Test func formatReportsMountFailureAfterSuccess() async {
    let h = makeHarness(disks: [gptDisk4, efi4, disk("disk4s2", name: "BACKUP")], mounted: false)
    let inventory = h.inventory
    let after = [gptDisk4, efi4, disk("disk4s2", kind: "exfat", name: "DRIVEWAYTMP", path: "/Volumes/DRIVEWAYTMP")]
    h.runner.onRun { if $0.arguments.first == "eraseDisk" { inventory.setDisks(after) } }
    let r = FormatRequest(filesystem: .ntfs, label: "NEW", scheme: .gpt, target: .wholeDisk("disk4"), confirmation: "BACKUP", expectedKey: "UUID-disk4")
    let response = await h.service.handle(.format(r), authorization: auth)
    #expect(response == .error(.commandFailed(
        "The drive was formatted, but mounting it failed: The drive didn't appear in Finder after mounting.")))
    #expect(h.runner.commands.contains(cmd(tools.mkntfs, "--quick", "--label", "NEW", "/dev/disk4s2")))
}

@Test func checkReportsRemountFailure() async {
    let missing = "\(ntfs3g) is not installed."
    // ntfs-3g fails, macOS's read-only mount comes back.
    let h = makeHarness(disks: [disk("disk4s1", name: "BACKUP", path: "/Volumes/BACKUP")], headers: ["disk4s1": ntfsHeader])
    h.runner.script(tools.ntfsfix, "-n", exit: 0, stdout: ntfsfixOK)
    h.runner.fail(ntfs3g, "/dev/disk4s1", with: CommandRunnerError.toolMissing(ntfs3g))
    guard case .report(let r) = await h.service.handle(.check(ref("disk4s1")), authorization: nil) else {
        Issue.record("expected report")
        return
    }
    #expect(r.succeeded)  // the check itself passed
    let readOnly = "The drive is now mounted read-only by macOS, because mounting it with Driveway failed: \(missing)"
    #expect(r.summary == "No problems found. " + readOnly)
    #expect(r.rawOutput.hasSuffix(readOnly))

    // ntfs-3g fails and macOS can't mount it either.
    let h2 = makeHarness(disks: [disk("disk4s1", name: "BACKUP", path: "/Volumes/BACKUP")], headers: ["disk4s1": ntfsHeader])
    h2.runner.script(tools.ntfsfix, "-n", exit: 0, stdout: ntfsfixOK)
    h2.runner.fail(ntfs3g, "/dev/disk4s1", with: CommandRunnerError.toolMissing(ntfs3g))
    h2.runner.script(diskutil, "mount", exit: 1, stderr: "busy")
    guard case .report(let r2) = await h2.service.handle(.check(ref("disk4s1")), authorization: nil) else {
        Issue.record("expected report")
        return
    }
    #expect(r2.succeeded)
    #expect(r2.summary == "No problems found. The drive couldn't be mounted again: \(missing)")
}

@Test func backupReportsRemountFailure() async {
    let missing = "\(ntfs3g) is not installed."
    let h = makeHarness(disks: [disk("disk4s1", name: "BACKUP", path: "/Volumes/BACKUP")], headers: ["disk4s1": ntfsHeader])
    h.runner.fail(ntfs3g, "/dev/disk4s1", with: CommandRunnerError.toolMissing(ntfs3g))
    #expect(await h.service.handle(.backup(ref("disk4s1"), imagePath: "/Users/x/b.img"), authorization: auth) == .error(.commandFailed(
        "The backup was saved. The drive is now mounted read-only by macOS, because mounting it with Driveway failed: \(missing)")))

    let h2 = makeHarness(disks: [disk("disk4s1", name: "BACKUP", path: "/Volumes/BACKUP")], headers: ["disk4s1": ntfsHeader])
    h2.runner.fail(ntfs3g, "/dev/disk4s1", with: CommandRunnerError.toolMissing(ntfs3g))
    h2.runner.script(diskutil, "mount", exit: 1, stderr: "busy")
    #expect(await h2.service.handle(.backup(ref("disk4s1"), imagePath: "/Users/x/b.img"), authorization: auth) == .error(.commandFailed(
        "The backup was saved. The drive couldn't be mounted again: \(missing)")))
}

@Test func failedHandBackIsAnEvent() async {
    let d = disk("disk4s1", name: "BACKUP")
    let console = ConsoleBox(ConsoleUser(uid: 501, gid: 20))
    let h = makeHarness(disks: [d], headers: ["disk4s1": ntfsHeader], consoleProvider: { console.value })
    _ = await h.service.handle(.backendStatus, authorization: nil)
    _ = await h.service.handle(.listVolumes, authorization: nil)
    #expect(!h.service.shouldApproveMacOSMount(d))
    console.value = nil
    h.runner.script(diskutil, "mount", exit: 1, stderr: "nope\n")
    let event = await h.service.diskAppeared(d)
    guard case .mountFailed(let v, let message) = event else { Issue.record("expected .mountFailed, got \(String(describing: event))"); return }
    #expect(message == "nope")
    #expect(v.bsdName == "disk4s1")
    #expect(v.lastError == "nope")
}

@Test func enablingDiskImagesNeedsAuthorization() async {
    let denied = makeHarness(disks: [], auth: false, settings: DrivewaySettings(fskitFailedOnOSBuild: osBuild))
    #expect(await denied.service.handle(.setSettings(DrivewaySettings(allowDiskImagesForTesting: true)), authorization: nil) == .error(.notAuthorized))
    #expect(denied.settings.current == DrivewaySettings(fskitFailedOnOSBuild: osBuild))
    // Other changes need no authorization.
    #expect(await denied.service.handle(.setSettings(DrivewaySettings(autoMountNTFS: false)), authorization: nil) == .ok)
    #expect(denied.settings.current.autoMountNTFS == false)

    let allowed = makeHarness(disks: [], auth: true)
    #expect(await allowed.service.handle(.setSettings(DrivewaySettings(allowDiskImagesForTesting: true)), authorization: auth) == .ok)
    #expect(allowed.settings.current.allowDiskImagesForTesting)

    // Turning it off again needs no authorization.
    let on = makeHarness(disks: [], auth: false, settings: DrivewaySettings(allowDiskImagesForTesting: true))
    #expect(await on.service.handle(.setSettings(DrivewaySettings(allowDiskImagesForTesting: false)), authorization: nil) == .ok)
    #expect(!on.settings.current.allowDiskImagesForTesting)
}

@Test func setSettingsNeverOverwritesFSKitRecord() async {
    let h = makeHarness(disks: [], settings: DrivewaySettings(fskitFailedOnOSBuild: osBuild))
    #expect(await h.service.handle(.setSettings(DrivewaySettings(fskitFailedOnOSBuild: "OTHER")), authorization: nil) == .ok)
    #expect(h.settings.current.fskitFailedOnOSBuild == osBuild)
    #expect(await h.service.handle(.setSettings(DrivewaySettings(fskitFailedOnOSBuild: nil)), authorization: nil) == .ok)
    #expect(h.settings.current.fskitFailedOnOSBuild == osBuild)

    let empty = makeHarness(disks: [])
    #expect(await empty.service.handle(.setSettings(DrivewaySettings(fskitFailedOnOSBuild: osBuild)), authorization: nil) == .ok)
    #expect(empty.settings.current.fskitFailedOnOSBuild == nil)
}

@Test func fskitFailureIsRememberedWhenSaveFails() async {
    let d = disk("disk4s1", name: "BACKUP")
    let h = makeHarness(disks: [d], headers: ["disk4s1": ntfsHeader], probe: .fskit, mounted: false, failSaves: true)
    guard case .mountFailed = await h.service.diskAppeared(d) else { Issue.record("expected .mountFailed"); return }
    #expect(h.settings.current.fskitFailedOnOSBuild == nil)  // the save failed
    #expect(await h.service.handle(.backendStatus, authorization: nil) == .backend(.unavailable))
    #expect(h.logs.value.count == 1)
    #expect(h.logs.value.first?.contains(osBuild) == true)
}

@Test func inventoryNamesAreCheckedBeforeDevPaths() async {
    let odd = disk("disk4s1", whole: "disk4; rm -rf /", name: "BACKUP")
    let h = makeHarness(disks: [odd], headers: ["disk4s1": ntfsHeader])
    #expect(await h.service.handle(.eject(ref("disk4s1")), authorization: nil)
        == .error(.commandFailed("The drive reported an unexpected disk name. Nothing was ejected.")))
    #expect(h.runner.commands.isEmpty)

    let h2 = makeHarness(disks: [gptDisk4, efi4, disk("disk4s2", name: "BACKUP")])
    let inventory = h2.inventory
    let bogus = disk("disk4s2x", whole: "disk4", kind: "exfat", name: "DRIVEWAYTMP")
    h2.runner.onRun { if $0.arguments.first == "eraseDisk" { inventory.setDisks([gptDisk4, efi4, bogus]) } }
    let r = FormatRequest(filesystem: .ntfs, label: "NEW", scheme: .gpt, target: .wholeDisk("disk4"), confirmation: "BACKUP", expectedKey: "UUID-disk4")
    #expect(await h2.service.handle(.format(r), authorization: auth)
        == .error(.commandFailed("The drive reported an unexpected partition name. Nothing was formatted.")))
    #expect(h2.runner.commands == [cmd(diskutil, "eraseDisk", "ExFAT", "DRIVEWAYTMP", "GPT", "/dev/disk4")])
}

// MARK: - Review round 2: claims beat formatting, scoped reset, eject key, deferred removals

@Test func freshlyFormattedVolumeIsNotHandedToMacOSDuringDrivewaysMount() async {
    let newVolume = disk("disk4s2", kind: "ntfs", name: "NEW")
    // The backend probe runs inside the post-format mount, before ntfs-3g claims the volume.
    let serviceBox = Box<HelperService?>(nil)
    let duringProbe = Box<[Bool]>([])
    var probe = FakeProbe.kernel
    probe.onProbe = { if let s = serviceBox.value { duringProbe.value.append(s.shouldApproveMacOSMount(newVolume)) } }
    let h = makeHarness(disks: [gptDisk4, efi4, disk("disk4s2", name: "BACKUP")], probe: probe)
    serviceBox.value = h.service
    let service = h.service
    let inventory = h.inventory
    let after = [gptDisk4, efi4, disk("disk4s2", kind: "exfat", name: "DRIVEWAYTMP", path: "/Volumes/DRIVEWAYTMP")]
    let duringMount = Box<[Bool]>([])
    h.runner.onRun { c in
        if c.arguments.first == "eraseDisk" { inventory.setDisks(after) }
        if c.executable == tools.ntfs3g { duringMount.value.append(service.shouldApproveMacOSMount(newVolume)) }
    }
    let r = FormatRequest(filesystem: .ntfs, label: "NEW", scheme: .gpt, target: .wholeDisk("disk4"), confirmation: "BACKUP", expectedKey: "UUID-disk4")
    guard case .volume(let v?) = await h.service.handle(.format(r), authorization: auth) else { Issue.record("expected volume"); return }
    #expect(v.mountedBy == .driveway)
    #expect(duringMount.value == [false])
    #expect(duringProbe.value == [false])
    #expect(!h.service.shouldApproveMacOSMount(newVolume))  // still Driveway's afterwards
}

@Test func partitionFormatKeepsSiblingsRefusedMount() async {
    let sibling = disk("disk4s1", name: "ONE")
    let console = ConsoleBox(ConsoleUser(uid: 501, gid: 20))
    let h = makeHarness(disks: [sibling, disk("disk4s2", name: "BACKUP")], consoleProvider: { console.value })
    _ = await h.service.handle(.backendStatus, authorization: nil)
    _ = await h.service.handle(.listVolumes, authorization: nil)
    #expect(!h.service.shouldApproveMacOSMount(sibling))  // macOS's mount of disk4s1 refused

    let service = h.service
    let duringErase = Box<[Bool]>([])
    h.runner.onRun { c in
        if c.arguments.first == "eraseVolume" { duringErase.value.append(service.shouldApproveMacOSMount(sibling)) }
    }
    let r = FormatRequest(filesystem: .exfat, label: "STICK", scheme: .gpt, target: .partition("disk4s2"), confirmation: "BACKUP", expectedKey: "UUID-disk4s2")
    #expect(await h.service.handle(.format(r), authorization: auth) == .ok)
    #expect(duringErase.value == [false])  // a refusal beats the format mark
    #expect(!h.service.shouldApproveMacOSMount(sibling))  // still refused: disk4s1 wasn't erased

    console.value = nil  // the sibling's turn comes, and it's left to macOS: the refused mount is handed back
    #expect(await h.service.diskAppeared(sibling) == nil)
    #expect(h.runner.commands.last == cmd(diskutil, "mount", "/dev/disk4s1"))
}

@Test func ejectOnlyTheQueuedWholeDisk() async {
    let h = makeHarness(disks: [disk("disk4s1", whole: "disk7", name: "BACKUP")], headers: ["disk4s1": ntfsHeader])
    #expect(await h.service.handle(.eject(ref("disk4s1")), authorization: nil)
        == .error(.commandFailed("The drive reported an unexpected disk name. Nothing was ejected.")))
    #expect(h.runner.commands.isEmpty)
}

@Test func removalDuringFormatKeepsTheNewMount() async {
    let h = makeHarness(disks: [gptDisk4, efi4, disk("disk4s2", name: "BACKUP", path: "/Volumes/BACKUP")])
    let inventory = h.inventory
    let after = [gptDisk4, efi4, disk("disk4s2", kind: "exfat", name: "DRIVEWAYTMP", path: "/Volumes/DRIVEWAYTMP")]
    h.runner.onRun { if $0.arguments.first == "eraseDisk" { inventory.setDisks(after) } }
    let gate = h.runner.hold(ntfs3g, "/dev/disk4s2")
    let service = h.service
    let r = FormatRequest(filesystem: .ntfs, label: "NEW", scheme: .gpt, target: .wholeDisk("disk4"), confirmation: "BACKUP", expectedKey: "UUID-disk4")
    async let formatted = service.handle(.format(r), authorization: auth)
    await gate.reached.wait()
    // DiskArbitration reports the erase's removal of the old disk4s2 late, while Driveway is mounting the new one.
    #expect(await service.diskDisappeared("disk4s2") == .removed(bsdName: "disk4s2"))
    gate.open()
    guard case .volume(let v?) = await formatted else { Issue.record("expected volume"); return }

    // disk4s2 is still in the inventory, so the claim and the mount record survive.
    // (DiskArbitration may still call the new volume "exfat"; only the claim refuses macOS here.)
    #expect(!service.shouldApproveMacOSMount(disk("disk4s2", kind: "exfat", name: "NEW")))
    let before = h.runner.commands.count
    #expect(await service.handle(.mount(ref("disk4s2")), authorization: nil) == .volume(v))
    #expect(h.runner.commands.count == before)
}

@Test func removalDuringOperationForgetsDiskThatStaysGone() async {
    let d = disk("disk4s1", name: "BACKUP")
    let h = makeHarness(disks: [d], headers: ["disk4s1": ntfsHeader])
    let gate = h.runner.hold(ntfs3g, "/dev/disk4s1")
    let service = h.service
    async let appeared = service.diskAppeared(d)
    await gate.reached.wait()
    #expect(await service.diskDisappeared("disk4s1") == .removed(bsdName: "disk4s1"))
    h.inventory.setDisks([])  // unplugged for good
    gate.open()
    _ = await appeared

    h.inventory.setDisks([d])  // plugged in again later: no stale "already mounted"
    let before = h.runner.commands.count
    _ = await service.handle(.mount(ref("disk4s1")), authorization: nil)
    #expect(h.runner.commands.count > before)
}

// MARK: - Final review: read-only fallback after exit 0 (C2)

@Test func exitZeroReadOnlyHibernatedFallsBackLikeExit14() async {
    let d = disk("disk4s1", name: "BACKUP")
    let h = makeHarness(disks: [d], headers: ["disk4s1": ntfsHeader])
    h.runner.script(ntfs3g, "/dev/disk4s1", exit: 0, stderr: """
        Windows is hibernated, refused to mount.
        Falling back to read-only mount because the NTFS partition is in an
        unsafe state. Please resume and shutdown Windows fully (no hibernation
        or fast restarting.)
        """)
    h.inventory.setReadOnlyMounts(["/Volumes/BACKUP"])
    let event = await h.service.diskAppeared(d)
    guard case .mountedReadOnly(let v, let reason) = event else {
        Issue.record("expected .mountedReadOnly, got \(String(describing: event))")
        return
    }
    #expect(reason == .hibernated)
    #expect(v.access == .readOnly)
    #expect(v.health == .hibernated)
    #expect(v.mountedBy == .macOS)
    #expect(Array(h.runner.commands.suffix(2)) == [unmount4s1, cmd(diskutil, "mount", "/dev/disk4s1")])
    #expect(h.service.shouldApproveMacOSMount(d))
    // The health stays visible in the list.
    guard case .volumes(let list) = await h.service.handle(.listVolumes, authorization: nil) else { Issue.record("expected volumes"); return }
    #expect(list.first?.health == .hibernated)
    #expect(list.first?.mountedBy != .driveway)
}

@Test func exitZeroReadOnlyUncleanFallsBackLikeExit15() async {
    let d = disk("disk4s1", name: "BACKUP")
    let h = makeHarness(disks: [d], headers: ["disk4s1": ntfsHeader])
    h.runner.script(ntfs3g, "/dev/disk4s1", exit: 0, stderr: "The file system wasn't safely closed on Windows.\n")
    h.inventory.setReadOnlyMounts(["/Volumes/BACKUP"])
    let event = await h.service.diskAppeared(d)
    guard case .mountedReadOnly(let v, let reason) = event else {
        Issue.record("expected .mountedReadOnly, got \(String(describing: event))")
        return
    }
    #expect(reason == .dirty)
    #expect(v.access == .readOnly)
    #expect(v.health == .dirty)
    #expect(Array(h.runner.commands.suffix(2)) == [unmount4s1, cmd(diskutil, "mount", "/dev/disk4s1")])
    guard case .volumes(let list) = await h.service.handle(.listVolumes, authorization: nil) else { Issue.record("expected volumes"); return }
    #expect(list.first?.health == .dirty)
}

@Test func explicitMountThatFallsBackIsNotReportedReadWrite() async {
    let d = disk("disk4s1", name: "BACKUP")
    let h = makeHarness(disks: [d], headers: ["disk4s1": ntfsHeader])
    h.runner.script(ntfs3g, "/dev/disk4s1", exit: 0)
    h.inventory.setReadOnlyMounts(["/Volumes/BACKUP"])
    let v = mountedVolume(await h.service.handle(.mount(ref("disk4s1")), authorization: nil))
    #expect(v?.access == .readOnly)
    #expect(v?.health == .dirty)
    #expect(v?.mountedBy == .macOS)
}

// MARK: - Final review: EFI is refused (I1)

@Test func efiPartitionIsRefusedForEveryOperation() async {
    let efi = disk("disk4s1", kind: "msdos", content: "EFI", name: "EFI", path: "/Volumes/EFI", size: 209_715_200)
    let efiByGUID = disk("disk5s1", kind: "msdos", content: "C12A7328-F81F-11D2-BA4B-00A0C93EC93B", name: "EFI")
    let h = makeHarness(disks: [gptDisk4, efi, disk("disk4s2", name: "BACKUP"), efiByGUID])
    for bsd in ["disk4s1", "disk5s1"] {
        let requests: [HelperRequest] = [
            .mount(ref(bsd)), .unmount(ref(bsd)), .eject(ref(bsd)), .fixAndMount(ref(bsd)), .check(ref(bsd)),
            .repair(ref(bsd), force: false), .backup(ref(bsd), imagePath: "/Users/x/b.img"),
            // Format refuses EFI before validation: even a matching name and a valid request are refused.
            .format(FormatRequest(filesystem: .exfat, label: "X", scheme: .gpt, target: .partition(bsd), confirmation: "EFI", expectedKey: "UUID-\(bsd)")),
            .format(FormatRequest(filesystem: .exfat, label: "", scheme: .gpt, target: .partition(bsd), confirmation: "nope", expectedKey: "UUID-\(bsd)")),
        ]
        for r in requests {
            #expect(await h.service.handle(r, authorization: auth) == .error(.protectedDisk), "\(r)")
        }
    }
    #expect(h.runner.commands.isEmpty)
}

// MARK: - Final review: long operations have no time limit (I2)

@Test func checkRepairBackupAndFormatRunWithoutTimeLimit() async {
    let h = makeHarness(disks: [disk("disk4s1", name: "BACKUP", path: "/Volumes/BACKUP")], headers: ["disk4s1": ntfsHeader])
    h.runner.script(tools.ntfsfix, "-n", exit: 0, stdout: ntfsfixOK)
    h.runner.script(tools.ntfsfix, "-d", exit: 0, stdout: ntfsfixOK)
    _ = await h.service.handle(.check(ref("disk4s1")), authorization: nil)
    _ = await h.service.handle(.repair(ref("disk4s1"), force: false), authorization: auth)
    _ = await h.service.handle(.fixAndMount(ref("disk4s1")), authorization: auth)
    _ = await h.service.handle(.backup(ref("disk4s1"), imagePath: "/Users/x/b.img"), authorization: auth)
    let tools = Set(h.unbounded.commands.map(\.executable))
    #expect(tools == [ToolPaths().ntfsfix, ToolPaths().ntfsclone])
    // Mounts and unmounts keep their time limit.
    #expect(!h.unbounded.commands.contains { $0.executable == ntfs3g || $0.arguments.first == "unmount" })

    let e = makeHarness(disks: [disk("disk6s1", kind: nil, content: "Linux Filesystem", name: "LINUX")], headers: ["disk6s1": ext4Header])
    _ = await e.service.handle(.check(ref("disk6s1")), authorization: nil)
    #expect(e.unbounded.commands == [cmd(ToolPaths().e2fsck, "-n", "-f", "/dev/disk6s1")])

    let x = makeHarness(disks: [disk("disk5s1", kind: "exfat", name: "STICK", path: "/Volumes/STICK")])
    _ = await x.service.handle(.repair(ref("disk5s1"), force: false), authorization: auth)
    #expect(x.unbounded.commands == [cmd(diskutil, "repairVolume", "/dev/disk5s1")])
}

@Test func formatRunsWithoutTimeLimitButMountsWithOne() async {
    let mbrDisk4 = disk("disk4", wholeMedia: true, kind: nil, content: "FDisk_partition_scheme", name: nil)
    let h = makeHarness(disks: [mbrDisk4, disk("disk4s1", name: "BACKUP", path: "/Volumes/BACKUP")])
    let after = [gptDisk4, efi4, disk("disk4s2", kind: "exfat", name: "DRIVEWAYTMP", path: "/Volumes/DRIVEWAYTMP")]
    let inventory = h.inventory
    h.runner.onRun { if $0.arguments.first == "eraseDisk" { inventory.setDisks(after) } }
    let r = FormatRequest(filesystem: .ntfs, label: "NEW", scheme: .gpt, target: .wholeDisk("disk4"), confirmation: "BACKUP", expectedKey: "UUID-disk4")
    _ = await h.service.handle(.format(r), authorization: auth)
    #expect(h.unbounded.commands == [
        cmd(diskutil, "eraseDisk", "ExFAT", "DRIVEWAYTMP", "GPT", "/dev/disk4"),
        cmd(diskutil, "unmount", "/dev/disk4s2"),
        cmd(tools.mkntfs, "--quick", "--label", "NEW", "/dev/disk4s2"),
    ])
    #expect(h.runner.commands.last?.executable == ntfs3g)
}

// MARK: - Final review: requests carry the drive's identity (I3)

@Test func requestForASwappedDriveIsRefused() async {
    // The user confirmed drive A as disk4s1; by the time the request arrives, drive B has that BSD name.
    let driveB = disk("disk4s1", name: "OTHER", path: "/Volumes/OTHER")
    let h = makeHarness(disks: [gptDisk4, driveB, disk("disk4s2", name: "TWO")], headers: ["disk4s1": ntfsHeader])
    let a = DiskRef(bsdName: "disk4s1", key: "UUID-of-drive-A")
    let requests: [HelperRequest] = [
        .mount(a), .unmount(a), .eject(a), .fixAndMount(a), .check(a), .repair(a, force: false), .repair(a, force: true),
        .backup(a, imagePath: "/Users/x/b.img"),
        .format(FormatRequest(filesystem: .exfat, label: "X", scheme: .gpt, target: .partition("disk4s1"), confirmation: "OTHER", expectedKey: a.key)),
        .format(FormatRequest(filesystem: .exfat, label: "X", scheme: .gpt, target: .wholeDisk("disk4"), confirmation: "OTHER", expectedKey: a.key)),
    ]
    for r in requests {
        #expect(await h.service.handle(r, authorization: auth) == .error(.unknownVolume), "\(r)")
    }
    #expect(h.runner.commands.isEmpty)

    // A whole-disk erase is confirmed by the key of any volume on that disk.
    let r = FormatRequest(filesystem: .exfat, label: "X", scheme: .gpt, target: .wholeDisk("disk4"), confirmation: "OTHER", expectedKey: "UUID-disk4s2")
    #expect(await h.service.handle(.format(r), authorization: auth) == .ok)
}

@Test func driveMountedByDrivewayKeepsTheKeyItWasShownWith() async {
    let before = disk("disk4s1", name: "BACKUP")
    let h = makeHarness(disks: [before], headers: ["disk4s1": ntfsHeader])
    guard case .mounted(let v) = await h.service.diskAppeared(before) else { Issue.record("expected mounted"); return }
    // DiskArbitration describes the volume differently once it's a FUSE mount.
    var after = before
    after.volumeUUID = nil
    after.volumeKind = "macfuse"
    after.volumePath = "/Volumes/BACKUP"
    h.inventory.setDisks([after])
    #expect(await h.service.handle(.unmount(DiskRef(v)), authorization: nil) == .ok)
}

// MARK: - Final review: the whole disk's size and unlisted partitions (I4)

@Test func listedVolumesKnowTheirDiskAndItsOtherPartitions() async {
    let disks = [
        disk("disk4", wholeMedia: true, kind: nil, content: "GUID_partition_scheme", name: nil, size: 64_000_000_000),
        disk("disk4s1", kind: "msdos", content: "EFI", name: "EFI", size: 209_715_200),
        disk("disk4s2", name: "DATA", path: "/Volumes/DATA", size: 30_000_000_000),
        disk("disk4s3", kind: nil, content: "Microsoft Basic Data", name: nil, size: 30_000_000_000),  // BitLocker
        disk("disk4s4", kind: nil, content: "Linux Swap", name: nil, size: 2_000_000_000),
    ]
    let h = makeHarness(disks: disks, headers: ["disk4s2": ntfsHeader])
    guard case .volumes(let list) = await h.service.handle(.listVolumes, authorization: nil) else { Issue.record("expected volumes"); return }
    #expect(list.map(\.bsdName) == ["disk4s2"])
    #expect(list.first?.diskSizeBytes == 64_000_000_000)
    #expect(list.first?.otherPartitionCount == 2)

    // A volume Driveway mounted reports the same.
    guard case .mounted(let v) = await h.service.diskAppeared(disks[2]) else { Issue.record("expected mounted"); return }
    #expect(v.diskSizeBytes == 64_000_000_000)
    #expect(v.otherPartitionCount == 2)
    guard case .volumes(let again) = await h.service.handle(.listVolumes, authorization: nil) else { Issue.record("expected volumes"); return }
    #expect(again.first?.mountedBy == .driveway)
    #expect(again.first?.otherPartitionCount == 2)
}

// MARK: - Final review: drives are evaluated again after login and Setup (I5)

@Test func driveLeftAtTheLoginWindowIsTakenOverAfterLogin() async {
    let d = disk("disk4s1", name: "BACKUP")
    let console = ConsoleBox(nil)
    let h = makeHarness(disks: [d], headers: ["disk4s1": ntfsHeader], consoleProvider: { console.value })
    #expect(await h.service.diskAppeared(d) == nil)  // nobody logged in: left to macOS
    #expect(h.runner.commands.isEmpty)

    // macOS mounted it read-only meanwhile; then someone logs in.
    var mountedByMacOS = d
    mountedByMacOS.volumePath = "/Volumes/BACKUP"
    h.inventory.setDisks([mountedByMacOS])
    console.value = ConsoleUser(uid: 501, gid: 20)
    let events = await h.service.reevaluateDrives()
    guard events.count == 1, case .mounted(let v) = events[0] else { Issue.record("expected one .mounted, got \(events)"); return }
    #expect(v.access == .readWrite)
    #expect(v.mountedBy == .driveway)
    #expect(h.runner.commands == [unmount4s1, ntfs3gBackup])

    // Evaluating again changes nothing: Driveway holds it now.
    #expect(await h.service.reevaluateDrives().isEmpty)
    #expect(h.runner.commands.count == 2)
}

@Test func driveAttachedBeforeSetupIsTakenOverOnceNTFSWritingIsReady() async {
    let d = disk("disk4s1", name: "BACKUP")
    let features = Box<[Feature: FeatureState]>([.readNTFS: .ready, .writeNTFS: .notAvailableYet])
    let h = makeHarness(disks: [d], headers: ["disk4s1": ntfsHeader], featuresProvider: { features.value })
    #expect(await h.service.diskAppeared(d) == nil)
    features.value = allReady
    let events = await h.service.reevaluateDrives()
    guard events.count == 1, case .mounted = events[0] else { Issue.record("expected one .mounted, got \(events)"); return }
    #expect(h.runner.commands == [ntfs3gBackup])
}

@Test func reevaluationLeavesOtherDrivesAlone() async {
    let tuxera = disk("disk5s1", kind: "tuxera_ntfs", name: "TUX", path: "/Volumes/TUX")
    let exfat = disk("disk6s1", kind: "exfat", name: "STICK", path: "/Volumes/STICK")
    let ownMount = disk("disk7s1", kind: "macfuse", name: "OLD", path: "/Volumes/OLD")
    let dirty = disk("disk8s1", name: "DIRTY")
    let h = makeHarness(
        disks: [tuxera, exfat, ownMount, dirty],
        headers: ["disk5s1": ntfsHeader, "disk7s1": ntfsHeader, "disk8s1": ntfsHeader])
    h.runner.script(ntfs3g, "/dev/disk8s1", exit: 15)
    guard case .mountedReadOnly(_, .dirty) = await h.service.diskAppeared(dirty) else { Issue.record("expected dirty"); return }
    let before = h.runner.commands.count
    // Another driver's drive, a format Driveway doesn't manage, a FUSE mount, and a drive known to be dirty:
    // trying again can't help until it's fixed.
    #expect(await h.service.reevaluateDrives().isEmpty)
    #expect(h.runner.commands.count == before)
}

@Test func backendStatusRequestRefreshesTheFeatures() async {
    let seen = Box<[BackendAvailability]>([])
    let h = makeHarness(disks: [], backendChecked: { seen.value.append($0) })
    _ = await h.service.handle(.backendStatus, authorization: nil)
    #expect(seen.value == [.ready(.kernel)])
}

@Test func reevaluationTriggerFiresOnLoginAndOnNewlyReadyFeatures() {
    let user = ConsoleUser(uid: 501, gid: 20)
    let notReady: [Feature: FeatureState] = [.readNTFS: .ready, .writeNTFS: .notAvailableYet, .extDrives: .notAvailableYet]
    var t = ReevaluationTrigger(user: nil, features: notReady)
    func update(_ user: ConsoleUser?, _ features: [Feature: FeatureState]) -> Bool { t.update(user: user, features: features) }
    #expect(!update(nil, notReady))
    #expect(update(user, notReady))  // someone logged in
    #expect(!update(user, notReady))
    #expect(update(user, allReady))  // Setup finished
    #expect(!update(user, allReady))
    #expect(!update(nil, allReady))  // logged out: nothing to take over
    #expect(update(ConsoleUser(uid: 502, gid: 20), allReady))  // another user
    #expect(!update(ConsoleUser(uid: 502, gid: 20), notReady))  // features lost: nothing to do
    #expect(update(ConsoleUser(uid: 502, gid: 20), allReady))
}

// MARK: - Final review: a refused macOS mount is always released (I6)

@Test func refusedMountIsReleasedWhenTheBootDiskCantBeRead() async {
    let d = disk("disk4s1", name: "BACKUP")
    let h = makeHarness(disks: [d], headers: ["disk4s1": ntfsHeader])
    _ = await h.service.handle(.backendStatus, authorization: nil)
    _ = await h.service.handle(.listVolumes, authorization: nil)
    #expect(!h.service.shouldApproveMacOSMount(d))  // refused: Driveway means to mount it

    h.inventory.setBoot([])  // fail closed: Driveway won't touch it now
    #expect(await h.service.diskAppeared(d) == nil)
    #expect(h.runner.commands == [cmd(diskutil, "mount", "/dev/disk4s1")])
    #expect(h.service.shouldApproveMacOSMount(d))
}

@Test func refusedMountIsReleasedWhenTheDiskTurnsOutProtected() async {
    let d = disk("disk4s1", name: "BACKUP")
    let h = makeHarness(disks: [d], headers: ["disk4s1": ntfsHeader])
    _ = await h.service.handle(.backendStatus, authorization: nil)
    _ = await h.service.handle(.listVolumes, authorization: nil)
    #expect(!h.service.shouldApproveMacOSMount(d))

    h.inventory.setBoot(["disk0", "disk4"])  // it is a boot disk after all
    #expect(await h.service.diskAppeared(d) == nil)
    #expect(h.runner.commands == [cmd(diskutil, "mount", "/dev/disk4s1")])
    #expect(h.service.shouldApproveMacOSMount(d))
}

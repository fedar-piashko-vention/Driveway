import DrivewayCore
import DrivewayHelperKit
import DrivewayIPC
import Foundation
import Testing

// MARK: - Adopting mounts that survived a helper restart

@Test func adoptsExistingKernelMounts() async {
    let ntfs = disk("disk4s1", kind: "macfuse", name: "BACKUP", path: "/Volumes/BACKUP")
    let exfat = disk("disk5s1", kind: "exfat", name: "STICK", path: "/Volumes/STICK")
    let h = makeHarness(disks: [ntfs, exfat], headers: ["disk4s1": ntfsHeader])
    await h.service.adoptExistingMounts()
    #expect(h.runner.commands.isEmpty)

    guard case .volumes(let volumes) = await h.service.handle(.listVolumes, authorization: nil) else {
        Issue.record("expected volumes")
        return
    }
    let adopted = volumes.first { $0.bsdName == "disk4s1" }
    #expect(adopted?.mountedBy == .driveway)
    #expect(adopted?.access == .readWrite)
    #expect(adopted?.backend == .kernel)
    #expect(adopted?.filesystem == .ntfs)
    #expect(adopted?.mountPoint == "/Volumes/BACKUP")
    #expect(adopted?.health == .unknown)
    // Other volumes are untouched.
    #expect(volumes.first { $0.bsdName == "disk5s1" }?.mountedBy == .macOS)

    // Claimed: macOS may not mount it, and a Mount request doesn't mount it twice.
    #expect(!h.service.shouldApproveMacOSMount(ntfs))
    #expect(await h.service.handle(.mount(ref("disk4s1")), authorization: nil) == .volume(adopted))
    #expect(h.runner.commands.isEmpty)
}

@Test func adoptsFSKitMountsAndReadsAccessFromTheMount() async {
    let ext = disk("disk6s1", kind: "macfuse-local", name: "LINUX", path: "/Volumes/LINUX")
    let h = makeHarness(disks: [ext], headers: ["disk6s1": ext4Header])
    h.inventory.setReadOnlyMounts(["/Volumes/LINUX"])
    await h.service.adoptExistingMounts()
    guard case .volumes(let volumes) = await h.service.handle(.listVolumes, authorization: nil) else {
        Issue.record("expected volumes")
        return
    }
    #expect(volumes.count == 1)
    #expect(volumes.first?.mountedBy == .driveway)
    #expect(volumes.first?.backend == .fskit)
    #expect(volumes.first?.access == .readOnly)
    #expect(volumes.first?.filesystem == .ext4)
}

@Test func doesNotAdoptUnmountedOrProtectedDisks() async {
    let unmounted = disk("disk4s1", kind: "macfuse", name: "BACKUP", path: nil)
    let boot = disk("disk0s3", kind: "macfuse", name: "ODD", path: "/Volumes/ODD")
    let h = makeHarness(disks: [unmounted, boot], headers: ["disk4s1": ntfsHeader, "disk0s3": ntfsHeader])
    await h.service.adoptExistingMounts()
    #expect(h.service.shouldApproveMacOSMount(boot))
    guard case .volumes(let volumes) = await h.service.handle(.listVolumes, authorization: nil) else {
        Issue.record("expected volumes")
        return
    }
    #expect(volumes.allSatisfy { $0.mountedBy != .driveway })
}

// MARK: - Settings held in memory

@Test func mountApprovalDoesNotReadTheSettingsFile() async {
    let d = disk("disk4s1", kind: "ntfs", path: nil)
    let h = makeHarness(disks: [d], headers: ["disk4s1": ntfsHeader])
    // Fill the shared state the callback reads (boot disks, backend).
    _ = await h.service.handle(.listVolumes, authorization: nil)
    _ = await h.service.handle(.backendStatus, authorization: nil)
    let before = h.settings.loads
    #expect(!h.service.shouldApproveMacOSMount(d))
    #expect(h.service.shouldApproveMacOSMount(disk("disk5s1", kind: "exfat", path: nil)))
    #expect(h.settings.loads == before)
}

@Test func savedSettingsTakeEffectWithoutReloading() async {
    let d = disk("disk4s1", kind: "ntfs", path: nil)
    let h = makeHarness(disks: [d], headers: ["disk4s1": ntfsHeader])
    _ = await h.service.handle(.listVolumes, authorization: nil)
    _ = await h.service.handle(.backendStatus, authorization: nil)
    var s = DrivewaySettings()
    s.autoMountNTFS = false
    #expect(await h.service.handle(.setSettings(s), authorization: nil) == .ok)
    #expect(await h.service.handle(.getSettings, authorization: nil) == .settings(s))
    #expect(h.service.shouldApproveMacOSMount(d))
}

@Test func failedSaveKeepsTheOldSettings() async {
    let h = makeHarness(disks: [], failSaves: true)
    var s = DrivewaySettings()
    s.autoMountNTFS = false
    guard case .error = await h.service.handle(.setSettings(s), authorization: nil) else {
        Issue.record("expected an error")
        return
    }
    #expect(await h.service.handle(.getSettings, authorization: nil) == .settings(DrivewaySettings()))
}

// MARK: - Disk events that arrive out of order

@Test func appearedEventForAGoneDiskDoesNothing() async {
    // The watcher hands events to tasks, so a removal can overtake the appearance before it.
    let d = disk("disk4s1", kind: "ntfs", path: nil)
    let h = makeHarness(disks: [], headers: ["disk4s1": ntfsHeader])
    #expect(await h.service.diskAppeared(d) == nil)
    #expect(h.runner.commands.isEmpty)
    #expect(h.service.shouldApproveMacOSMount(d))
}

// Live session: DiskArbitration calls Driveway's NTFS mount "ntfs" (Apple's probe recognised the partition) and
// knows no mount at all for ext. The mount table's type is what shows the mount is Driveway's.

@Test func adoptsAnNTFSMountThatDiskArbitrationCallsNTFS() async {
    let ntfs = disk("disk4s1", kind: "ntfs", name: "BACKUP", path: "/Volumes/BACKUP")
    let h = makeHarness(disks: [ntfs], headers: ["disk4s1": ntfsHeader])
    h.inventory.setMountEntry(MountEntry(mountPoint: "/Volumes/BACKUP", type: "macfuse"), device: "/dev/disk4s1")
    await h.service.adoptExistingMounts()
    guard case .volumes(let volumes) = await h.service.handle(.listVolumes, authorization: nil) else {
        Issue.record("expected volumes")
        return
    }
    #expect(volumes.first?.mountedBy == .driveway)
    #expect(volumes.first?.backend == .kernel)
    #expect(h.runner.commands.isEmpty)
}

@Test func adoptsAnExtMountDiskArbitrationDoesNotKnow() async {
    let ext = disk("disk6s1", kind: nil, content: "Linux Filesystem", name: "LINUX")  // no volume path
    let h = makeHarness(disks: [ext], headers: ["disk6s1": ext4Header])
    h.inventory.setMountEntry(MountEntry(mountPoint: "/Volumes/LINUX", type: "macfuse"), device: "/dev/disk6s1")
    await h.service.adoptExistingMounts()
    guard case .volumes(let volumes) = await h.service.handle(.listVolumes, authorization: nil) else {
        Issue.record("expected volumes")
        return
    }
    #expect(volumes.first?.mountedBy == .driveway)
    #expect(volumes.first?.mountPoint == "/Volumes/LINUX")
    #expect(volumes.first?.access == .readOnly)  // ext4fuse only reads, whatever the mount flags say
}

@Test func doesNotAdoptMacOSsOwnNTFSMount() async {
    let ntfs = disk("disk4s1", kind: "ntfs", name: "BACKUP", path: "/Volumes/BACKUP")
    let h = makeHarness(disks: [ntfs], headers: ["disk4s1": ntfsHeader])
    h.inventory.setMountEntry(MountEntry(mountPoint: "/Volumes/BACKUP", type: "ntfs"), device: "/dev/disk4s1")
    await h.service.adoptExistingMounts()
    guard case .volumes(let volumes) = await h.service.handle(.listVolumes, authorization: nil) else {
        Issue.record("expected volumes")
        return
    }
    #expect(volumes.first?.mountedBy != .driveway)
}

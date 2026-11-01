import Testing

@testable import DrivewayCore

private let p = ToolPaths()

@Test func toolPathsMatchSpike() {
    #expect(p.brew == "/opt/homebrew/bin/brew")
    #expect(p.ntfs3g == "/opt/homebrew/bin/ntfs-3g")
    #expect(p.ntfsfix == "/opt/homebrew/bin/ntfsfix")
    #expect(p.ntfsinfo == "/opt/homebrew/bin/ntfsinfo")
    #expect(p.mkntfs == "/opt/homebrew/sbin/mkntfs")
    #expect(p.ntfsclone == "/opt/homebrew/sbin/ntfsclone")
    #expect(p.ext4fuse == "/opt/homebrew/bin/ext4fuse")
    #expect(p.e2fsck == "/opt/homebrew/opt/e2fsprogs/sbin/e2fsck")
    #expect(p.mkfsExt4 == "/opt/homebrew/opt/e2fsprogs/sbin/mkfs.ext4")
    #expect(p.diskutil == "/usr/sbin/diskutil")
    #expect(p.umount == "/sbin/umount")
    #expect(p.chown == "/usr/sbin/chown")
}

@Test func chownGivesAFileToAUserWithoutFollowingSymlinks() {
    #expect(
        ToolCommands.chown(path: "/Users/me/b.img", uid: 501, gid: 20, paths: p)
            == Command(executable: "/usr/sbin/chown", arguments: ["-h", "501:20", "/Users/me/b.img"]))
}

@Test func ntfs3gReadWriteMountKernel() {
    #expect(
        ToolCommands.ntfs3gMount(
            device: "/dev/disk4s1", mountPoint: "/Volumes/BACKUP", volumeName: "BACKUP",
            readOnly: false, uid: 501, gid: 20, backend: .kernel, paths: p)
            == Command(
                executable: "/opt/homebrew/bin/ntfs-3g",
                arguments: ["/dev/disk4s1", "/Volumes/BACKUP", "-o", "volname=BACKUP,uid=501,gid=20,norecover,user_xattr"]))
}

@Test func ntfs3gFSKitPutsBackendFirst() {
    #expect(
        ToolCommands.ntfs3gMount(
            device: "/dev/disk4s1", mountPoint: "/Volumes/BACKUP", volumeName: "BACKUP",
            readOnly: false, uid: 501, gid: 20, backend: .fskit, paths: p).arguments
            == ["/dev/disk4s1", "/Volumes/BACKUP", "-o", "backend=fskit,volname=BACKUP,uid=501,gid=20,norecover,user_xattr"])
}

@Test func ntfs3gReadOnlyAppendsRo() {
    let kernel = ToolCommands.ntfs3gMount(
        device: "/dev/disk4s1", mountPoint: "/Volumes/BACKUP", volumeName: "BACKUP",
        readOnly: true, uid: 501, gid: 20, backend: .kernel, paths: p)
    let fskit = ToolCommands.ntfs3gMount(
        device: "/dev/disk4s1", mountPoint: "/Volumes/BACKUP", volumeName: "BACKUP",
        readOnly: true, uid: 501, gid: 20, backend: .fskit, paths: p)
    #expect(kernel.arguments.last == "volname=BACKUP,uid=501,gid=20,norecover,user_xattr,ro")
    #expect(fskit.arguments.last == "backend=fskit,volname=BACKUP,uid=501,gid=20,norecover,user_xattr,ro")
}

@Test func ntfs3gEscapesVolumeName() {
    let cmd = ToolCommands.ntfs3gMount(
        device: "/dev/disk4s1", mountPoint: "/Volumes/a", volumeName: "a,b",
        readOnly: false, uid: 501, gid: 20, backend: .kernel, paths: p)
    #expect(cmd.arguments.last == "volname=a\\,b,uid=501,gid=20,norecover,user_xattr")
}

@Test func ext4fuseMountBackends() {
    let kernel = ToolCommands.ext4fuseMount(
        device: "/dev/disk5s1", mountPoint: "/Volumes/linux_home", volumeName: "linux_home",
        backend: .kernel, paths: p)
    #expect(kernel.executable == "/opt/homebrew/bin/ext4fuse")
    #expect(kernel.arguments == ["/dev/disk5s1", "/Volumes/linux_home", "-o", "volname=linux_home,allow_other,fsname=/dev/disk5s1"])
    let fskit = ToolCommands.ext4fuseMount(
        device: "/dev/disk5s1", mountPoint: "/Volumes/linux_home", volumeName: "linux_home",
        backend: .fskit, paths: p)
    #expect(
        fskit.arguments == [
            "/dev/disk5s1", "/Volumes/linux_home", "-o", "backend=fskit,volname=linux_home,allow_other,fsname=/dev/disk5s1",
        ])
}

@Test func ntfsfixModes() {
    #expect(ToolCommands.ntfsfix(device: "/dev/disk4s1", mode: .check, paths: p).arguments == ["-n", "/dev/disk4s1"])
    #expect(ToolCommands.ntfsfix(device: "/dev/disk4s1", mode: .repair, paths: p).arguments == ["-d", "/dev/disk4s1"])
    #expect(ToolCommands.ntfsfix(device: "/dev/disk4s1", mode: .check, paths: p).executable == "/opt/homebrew/bin/ntfsfix")
}

@Test func ntfsfixRepairForceBehavesLikeRepair() {
    #expect(
        ToolCommands.ntfsfix(device: "/dev/disk4s1", mode: .repairForce, paths: p)
            == ToolCommands.ntfsfix(device: "/dev/disk4s1", mode: .repair, paths: p))
}

@Test func e2fsckModes() {
    let dev = "/dev/disk5s1"
    #expect(ToolCommands.e2fsck(device: dev, mode: .check, paths: p).arguments == ["-n", "-f", "-C", "1", dev])
    #expect(ToolCommands.e2fsck(device: dev, mode: .repair, paths: p).arguments == ["-p", "-f", "-C", "1", dev])
    #expect(ToolCommands.e2fsck(device: dev, mode: .repairForce, paths: p).arguments == ["-y", "-f", "-C", "1", dev])
    #expect(ToolCommands.e2fsck(device: dev, mode: .check, paths: p).executable == "/opt/homebrew/opt/e2fsprogs/sbin/e2fsck")
}

@Test func ntfscloneSavesImage() {
    #expect(
        ToolCommands.ntfsclone(device: "/dev/disk4s1", imagePath: "/Users/me/b.img", paths: p)
            == Command(
                executable: "/opt/homebrew/sbin/ntfsclone",
                arguments: ["--save-image", "--force", "--overwrite", "/Users/me/b.img", "/dev/disk4s1"]))
}

@Test func diskutilPassesArgsThrough() {
    #expect(
        ToolCommands.diskutil("info", "-plist", "disk4", paths: p)
            == Command(executable: "/usr/sbin/diskutil", arguments: ["info", "-plist", "disk4"]))
}

@Test func unmountUsesDiskutil() {
    #expect(
        ToolCommands.unmount(device: "/dev/disk4s1", paths: p)
            == Command(executable: "/usr/sbin/diskutil", arguments: ["unmount", "/dev/disk4s1"]))
}

@Test func mountPointAndVolnameEdgeCases() {
    #expect(MountNaming.mountPoint(for: "BACKUP", existing: []) == "/Volumes/BACKUP")
    #expect(MountNaming.mountPoint(for: "BACKUP", existing: ["/Volumes/BACKUP"]) == "/Volumes/BACKUP 1")
    #expect(
        MountNaming.mountPoint(for: "BACKUP", existing: ["/Volumes/BACKUP", "/Volumes/BACKUP 1"])
            == "/Volumes/BACKUP 2")
    #expect(MountNaming.mountPoint(for: "", existing: []) == "/Volumes/Untitled")
    #expect(MountNaming.mountPoint(for: "  \t", existing: []) == "/Volumes/Untitled")
    #expect(MountNaming.mountPoint(for: "a/b", existing: []) == "/Volumes/a:b")
    #expect(MountNaming.mountPoint(for: "Фото 2024", existing: []) == "/Volumes/Фото 2024")
    #expect(MountNaming.fuseOptionEscaped("a,b\\c") == "a\\,b\\\\c")
}

@Test func mountPointRejectsDotNames() {
    #expect(MountNaming.mountPoint(for: ".", existing: []) == "/Volumes/Untitled")
    #expect(MountNaming.mountPoint(for: "..", existing: []) == "/Volumes/Untitled")
    #expect(MountNaming.mountPoint(for: " .. ", existing: []) == "/Volumes/Untitled")
}

@Test func mountPointCollisionIsCaseInsensitive() {
    #expect(MountNaming.mountPoint(for: "BACKUP", existing: ["/Volumes/backup"]) == "/Volumes/BACKUP 1")
    #expect(
        MountNaming.mountPoint(for: "BACKUP", existing: ["/Volumes/backup", "/Volumes/Backup 1"])
            == "/Volumes/BACKUP 2")
}

@Test func mountPointTrimsAndStripsControlCharacters() {
    #expect(MountNaming.mountPoint(for: " X ", existing: []) == "/Volumes/X")
    #expect(MountNaming.mountPoint(for: "a\nb", existing: []) == "/Volumes/ab")
    #expect(MountNaming.mountPoint(for: "a\u{0}b", existing: []) == "/Volumes/ab")
    #expect(MountNaming.mountPoint(for: "\n\u{0}", existing: []) == "/Volumes/Untitled")
}

@Test func mountPointNameIsCappedAtNameMax() {
    let ascii = String(repeating: "a", count: 300)
    let result = MountNaming.mountPoint(for: ascii, existing: [])
    #expect(result.hasPrefix("/Volumes/"))
    #expect(String(result.dropFirst("/Volumes/".count)).utf8.count <= 255)

    // Multi-byte characters are cut on a Character boundary, with room for a suffix.
    let cyrillic = String(repeating: "Ф", count: 300)
    let first = MountNaming.mountPoint(for: cyrillic, existing: [])
    let second = MountNaming.mountPoint(for: cyrillic, existing: [first])
    #expect(String(second.dropFirst("/Volumes/".count)).utf8.count <= 255)
    #expect(second != first)
    #expect(second.hasPrefix(first))
}

@Test func mkntfsIsQuickWithLabel() {
    #expect(
        ToolCommands.mkntfs(device: "/dev/disk4s2", label: "BACKUP", paths: p)
            == Command(
                executable: "/opt/homebrew/sbin/mkntfs",
                arguments: ["--quick", "--label", "BACKUP", "/dev/disk4s2"]))
}

@Test func mkfsExt4ForcesAndLabels() {
    #expect(
        ToolCommands.mkfsExt4(device: "/dev/disk4s2", label: "DATA", paths: p)
            == Command(
                executable: "/opt/homebrew/opt/e2fsprogs/sbin/mkfs.ext4",
                arguments: ["-F", "-L", "DATA", "/dev/disk4s2"]))
}

@Test func ntfscloneForcesPastTheDirtyFlag() {
    let c = ToolCommands.ntfsclone(device: "/dev/disk4s1", imagePath: "/Users/x/b.img", paths: p)
    #expect(c.executable == "/opt/homebrew/sbin/ntfsclone")
    #expect(c.arguments.contains("--force"))
}

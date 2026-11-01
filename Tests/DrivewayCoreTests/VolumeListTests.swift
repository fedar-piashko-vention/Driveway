import Foundation
import Testing
import DrivewayCore

private func volume(
    _ bsd: String, _ fs: FilesystemKind, access: AccessMode = .readWrite, health: VolumeHealth = .clean,
    mountedBy: MountOwner = .driveway, lastError: String? = nil
) -> Volume {
    Volume(
        bsdName: bsd, wholeDisk: "disk4", label: bsd.uppercased(), filesystem: fs, capacityBytes: 1_000,
        usedBytes: 100, mountPoint: "/Volumes/\(bsd)", access: access, health: health, mountedBy: mountedBy,
        deviceModel: "SSD", settingsKey: "key-\(bsd)", lastError: lastError)
}

struct VolumeListTests {
    @Test func sectionsSplitManagedFromOther() {
        let ntfs = volume("disk4s1", .ntfs)
        let exfat = volume("disk5s1", .exfat)
        let ext4 = volume("disk6s1", .ext4)
        let sections = VolumeList.sections([ntfs, exfat, ext4])
        #expect(sections.map(\.title) == ["NTFS / ext", "Other"])
        #expect(sections[0].volumes == [ntfs, ext4])
        #expect(sections[1].volumes == [exfat])

        #expect(VolumeList.sections([exfat]).map(\.title) == ["Other"])
        #expect(VolumeList.sections([ntfs]).map(\.title) == ["NTFS / ext"])
        #expect(VolumeList.sections([]).isEmpty)
    }

    @Test func healthTexts() {
        #expect(VolumeList.healthText(.clean) == "Clean")
        #expect(VolumeList.healthText(.dirty) == "Dirty — not shut down cleanly")
        #expect(VolumeList.healthText(.hibernated) == "Windows is hibernating")
        #expect(VolumeList.healthText(.unknown) == "Unknown")
    }

    @Test func banners() {
        #expect(VolumeList.banner(for: volume("disk4s1", .ntfs, access: .readOnly, health: .dirty)) == .dirty)
        #expect(
            VolumeList.banner(for: volume("disk4s1", .ntfs, access: .readOnly, health: .hibernated)) == .hibernated)
        #expect(
            VolumeList.banner(for: volume("disk4s1", .ntfs, mountedBy: .otherDriver("Tuxera NTFS")))
                == .otherDriver("Tuxera NTFS"))
        #expect(VolumeList.banner(for: volume("disk4s1", .ntfs, access: .readWrite, health: .clean)) == nil)
        #expect(
            VolumeList.banner(for: volume("disk4s1", .ntfs, access: .readOnly, health: .unknown, lastError: "x"))
                == .error("x"))
    }

    @Test func anotherDriverOutranksHealth() {
        let owned = volume("disk4s1", .ntfs, access: .readWrite, health: .dirty, mountedBy: .otherDriver("Paragon"))
        #expect(VolumeList.banner(for: owned) == .otherDriver("Paragon"))
    }

    @Test func volumeURLsNameTheBSDDevice() {
        #expect(VolumeList.bsdName(from: URL(string: "driveway://volume/disk4s1")!) == "disk4s1")
        #expect(VolumeList.bsdName(from: URL(string: "driveway://")!) == nil)
        #expect(VolumeList.bsdName(from: URL(string: "driveway://volume/")!) == nil)
        #expect(VolumeList.bsdName(from: URL(string: "driveway://other/disk4s1")!) == nil)
        #expect(VolumeList.bsdName(from: URL(string: "https://volume/disk4s1")!) == nil)
    }

    @Test func diskManagerCopy() {
        #expect(Copy.fixAndMount == "Fix & mount read/write")
        #expect(Copy.handledByMacOS == "handled by macOS")
        #expect(Copy.mountedBy("Tuxera NTFS") == "Mounted by Tuxera NTFS")
        #expect(Copy.autoMountNTFS == "Auto-mount NTFS read/write")
        #expect(Copy.alwaysMountReadOnly == "Always mount read-only")
    }
}

import Foundation

/// Decides which disks Driveway's helper must never touch: the boot disk, any disk
/// carrying APFS/HFS (or a disk image, unless allowed). Internal non-boot disks
/// such as an SD-card reader holding NTFS are allowed.
public struct ProtectionPolicy: Sendable {
    public var bootWholeDisks: Set<String>
    public var allowDiskImages: Bool

    /// `DAMediaContent` values, lowercased. MBR/APM media report "Apple_*" names; GPT media
    /// report partition-type GUIDs.
    static let protectedContentTypes: Set<String> = [
        "apple_apfs", "apple_apfs_isc", "apple_apfs_recovery", "apple_hfs", "apple_boot",
        "apple_corestorage", "apple_raid", "apple_raid_offline",
        "7c3457ef-0000-11aa-aa11-00306543ecac",  // APFS
        "ef57347c-0000-11aa-aa11-00306543ecac",  // APFS synthesized container
        "41504653-0000-11aa-aa11-00306543ecac",  // APFS volume
        "69646961-6700-11aa-aa11-00306543ecac",  // ISC
        "52637672-7900-11aa-aa11-00306543ecac",  // Recovery
        "48465300-0000-11aa-aa11-00306543ecac",  // HFS+
        "426f6f74-0000-11aa-aa11-00306543ecac",  // Apple Boot
        "53746f72-6167-11aa-aa11-00306543ecac",  // CoreStorage (Fusion Drive, legacy FileVault)
        "52414944-0000-11aa-aa11-00306543ecac",  // Apple RAID
        "52414944-5f4f-11aa-aa11-00306543ecac",  // Apple RAID, offline
    ]
    static let protectedVolumeKinds: Set<String> = ["apfs", "hfs"]

    public init(bootWholeDisks: Set<String> = [], allowDiskImages: Bool = false) {
        self.bootWholeDisks = bootWholeDisks
        self.allowDiskImages = allowDiskImages
    }

    /// `allDisks` must be the complete current snapshot of disks, since a protected sibling
    /// anywhere on the same whole disk protects `disk`. It need not contain `disk` itself;
    /// the disk always counts among its own siblings.
    public func isProtected(_ disk: DiskDescription, allDisks: [DiskDescription]) -> Bool {
        if bootWholeDisks.contains(disk.wholeDisk) { return true }
        if disk.isDiskImage && !allowDiskImages { return true }
        let siblings = allDisks.filter { $0.wholeDisk == disk.wholeDisk } + [disk]
        return siblings.contains(where: Self.carriesProtectedFilesystem)
    }

    private static func carriesProtectedFilesystem(_ d: DiskDescription) -> Bool {
        if let content = d.contentType, protectedContentTypes.contains(content.lowercased()) { return true }
        if let kind = d.volumeKind, protectedVolumeKinds.contains(kind.lowercased()) { return true }
        return false
    }

    /// Parses `diskutil info -plist /`: whole disks of `APFSPhysicalStores[].APFSPhysicalStore`
    /// (e.g. "disk0s2" -> "disk0"), else `ParentWholeDisk`. Malformed input gives an empty set.
    public static func bootWholeDisks(fromDiskutilInfoPlist data: Data) -> Set<String> {
        guard let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = object as? [String: Any]
        else { return [] }
        if let stores = dict["APFSPhysicalStores"] as? [[String: Any]] {
            let names = stores.compactMap { ($0["APFSPhysicalStore"] as? String).flatMap(wholeDiskName) }
            if !names.isEmpty { return Set(names) }
        }
        if let parent = dict["ParentWholeDisk"] as? String, !parent.isEmpty { return [parent] }
        return []
    }

    /// "disk0s2" -> "disk0"; nil when the name does not start with `disk<N>`.
    private static func wholeDiskName(_ bsdName: String) -> String? {
        guard bsdName.hasPrefix("disk") else { return nil }
        let digits = bsdName.dropFirst(4).prefix(while: \.isNumber)
        return digits.isEmpty ? nil : "disk" + digits
    }
}

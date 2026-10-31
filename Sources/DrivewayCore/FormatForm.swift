import Foundation

/// What the Format tab and the helper's validation errors say.
public enum FormatMessages {
    /// A short sentence for each validation error.
    public static func text(for error: FormatValidationError) -> String {
        switch error {
        case .labelTooLong(let max): "Name can be at most \(max) characters"
        case .invalidCharacters: "Name contains characters this format can't use"
        case .emptyLabel: "Enter a name"
        case .confirmationMismatch: "The name you typed doesn't match the drive."
        case .invalidTarget: "That isn't a drive Driveway can format."
        case .unsupportedFilesystem: "Driveway can't format with that filesystem."
        }
    }

    /// The errors shown below the name field; the rest belong to other parts of the form.
    public static func isLabelError(_ error: FormatValidationError) -> Bool {
        switch error {
        case .emptyLabel, .labelTooLong, .invalidCharacters: true
        case .confirmationMismatch, .invalidTarget, .unsupportedFilesystem: false
        }
    }

    /// The label error for the form as it stands, if any. The confirmation isn't typed yet, so the check runs with
    /// the drive's own name; errors that aren't about the label are not shown.
    public static func inlineError(
        filesystem: FilesystemKind, label: String, scheme: PartitionScheme, target: FormatTarget, driveName: String
    ) -> String? {
        let request = FormatRequest(
            filesystem: filesystem, label: label, scheme: scheme, target: target, confirmation: driveName)
        do throws(FormatValidationError) {
            try validate(request, currentDriveName: driveName)
            return nil
        } catch {
            return isLabelError(error) ? text(for: error) : nil
        }
    }
}

/// The Format tab's rules, kept out of the view so they can be tested.
public enum FormatForm {
    /// The filesystems the picker offers, in order.
    public static let choices: [FilesystemKind] = [.ntfs, .ext4, .exfat, .fat32]

    /// The volumes on the same physical disk as `volume` (including it). The helper's list leaves out EFI.
    static func siblings(of volume: Volume, in volumes: [Volume]) -> [Volume] {
        volumes.filter { $0.wholeDisk == volume.wholeDisk }
    }

    /// Whole media with no partition table (the volume is the disk itself) can only be erased as a whole disk.
    public static func isWholeDiskForced(_ volume: Volume) -> Bool {
        volume.bsdName == volume.wholeDisk
    }

    /// "Erase the whole disk" starts on when exactly one listed volume shares the disk, or it can't be anything else.
    public static func defaultsToWholeDisk(_ volume: Volume, in volumes: [Volume]) -> Bool {
        isWholeDiskForced(volume) || siblings(of: volume, in: volumes).count == 1
    }

    /// What the toggle means for this drive: forced on for whole media.
    public static func erasesWholeDisk(_ volume: Volume, toggle: Bool) -> Bool {
        isWholeDiskForced(volume) || toggle
    }

    /// True when the drive has an operation running. Erasing the whole disk also counts an operation on any other
    /// partition of that disk, listed or not.
    public static func isBusy(_ volume: Volume, wholeDisk: Bool, busy: Set<String>) -> Bool {
        if busy.contains(volume.bsdName) { return true }
        guard wholeDisk else { return false }
        return busy.contains { $0 == volume.wholeDisk || Formatting.isPartition($0, of: volume.wholeDisk) }
    }

    /// "NTFS · GPT · whole disk", or "NTFS · this partition": reformatting a partition keeps the partition table.
    public static func summary(of request: FormatRequest) -> String {
        switch request.target {
        case .wholeDisk: "\(request.filesystem.displayName) · \(request.scheme.rawValue) · whole disk"
        case .partition: "\(request.filesystem.displayName) · this partition"
        }
    }

    public static func target(for volume: Volume, wholeDisk: Bool) -> FormatTarget {
        wholeDisk ? .wholeDisk(volume.wholeDisk) : .partition(volume.bsdName)
    }

    /// The warning's lines. A partition: its own size. A whole disk: the size of every listed volume on it, and
    /// when there are others, a second line naming them.
    public static func warning(for volume: Volume, wholeDisk: Bool, in volumes: [Volume]) -> [String] {
        guard wholeDisk else {
            return [eraseWarning(label: volume.label, capacityBytes: volume.capacityBytes)]
        }
        let onDisk = siblings(of: volume, in: volumes)
        let others = onDisk.filter { $0.bsdName != volume.bsdName }
        // The volume is part of its disk even if the list no longer holds it.
        let total = onDisk.contains { $0.bsdName == volume.bsdName }
            ? onDisk.reduce(0) { $0 + $1.capacityBytes }
            : onDisk.reduce(volume.capacityBytes) { $0 + $1.capacityBytes }
        var lines = [eraseWarning(label: volume.label, capacityBytes: total)]
        if !others.isEmpty { lines.append("This also erases: " + others.map(\.label).joined(separator: ", ")) }
        return lines
    }

    /// NTFS needs NTFS writing, ext4 needs ext drives; exFAT and FAT32 are always available.
    public static func isAvailable(_ fs: FilesystemKind, ready: Set<Feature>) -> Bool {
        switch fs {
        case .ntfs: ready.contains(.writeNTFS)
        case .ext4: ready.contains(.extDrives)
        default: true
        }
    }

    /// The tooltip on a disabled filesystem; nil when it's available.
    public static func unavailableReason(_ fs: FilesystemKind, ready: Set<Feature>) -> String? {
        guard !isAvailable(fs, ready: ready) else { return nil }
        switch fs {
        case .ntfs: return "Driveway couldn't write to an NTFS drive on this Mac yet, so you couldn't use the result."
        case .ext4: return "ext drives aren't set up on this Mac yet, so you couldn't use the result."
        default: return nil
        }
    }

    /// `fs`, or exFAT when it has become unavailable.
    public static func effective(_ fs: FilesystemKind, ready: Set<Feature>) -> FilesystemKind {
        isAvailable(fs, ready: ready) ? fs : .exfat
    }

    public static func schemeTitle(_ scheme: PartitionScheme) -> String {
        switch scheme {
        case .gpt: "GPT"
        case .mbr: "MBR — \(Copy.forOlderPCs)"
        }
    }
}

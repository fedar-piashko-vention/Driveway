public enum FilesystemKind: String, Codable, Sendable, CaseIterable {
    case ntfs, ext2, ext3, ext4, exfat, fat32, fat16, other

    public var displayName: String {
        switch self {
        case .ntfs: "NTFS"
        case .ext2: "ext2"
        case .ext3: "ext3"
        case .ext4: "ext4"
        case .exfat: "exFAT"
        case .fat32: "FAT32"
        case .fat16: "FAT16"
        case .other: "Other"
        }
    }

    public var isDrivewayManaged: Bool {
        switch self {
        case .ntfs, .ext2, .ext3, .ext4: true
        case .exfat, .fat32, .fat16, .other: false
        }
    }
}

public enum AccessMode: String, Codable, Sendable {
    case readWrite, readOnly, notMounted
}

public enum VolumeHealth: String, Codable, Sendable {
    case clean, dirty, hibernated, unknown
}

public enum MountOwner: Codable, Equatable, Sendable {
    case driveway, macOS, otherDriver(String), none
}

public enum MountBackend: String, Codable, Sendable {
    case kernel, fskit
}

public struct DiskDescription: Codable, Equatable, Sendable {
    public var bsdName: String
    public var wholeDisk: String
    public var isWholeMedia: Bool
    public var isInternal: Bool
    public var isDiskImage: Bool
    /// DiskArbitration `DAVolumeKind`.
    public var volumeKind: String?
    /// DiskArbitration `DAVolumeType`, e.g. "MS-DOS FAT32".
    public var volumeType: String?
    /// DiskArbitration `DAMediaContent`.
    public var contentType: String?
    public var volumeName: String?
    public var volumeUUID: String?
    public var mediaUUID: String?
    public var sizeBytes: Int64
    public var deviceModel: String
    public var volumePath: String?

    public init(
        bsdName: String, wholeDisk: String, isWholeMedia: Bool, isInternal: Bool, isDiskImage: Bool,
        volumeKind: String?, volumeType: String?, contentType: String?, volumeName: String?,
        volumeUUID: String?, mediaUUID: String?, sizeBytes: Int64, deviceModel: String, volumePath: String?
    ) {
        self.bsdName = bsdName
        self.wholeDisk = wholeDisk
        self.isWholeMedia = isWholeMedia
        self.isInternal = isInternal
        self.isDiskImage = isDiskImage
        self.volumeKind = volumeKind
        self.volumeType = volumeType
        self.contentType = contentType
        self.volumeName = volumeName
        self.volumeUUID = volumeUUID
        self.mediaUUID = mediaUUID
        self.sizeBytes = sizeBytes
        self.deviceModel = deviceModel
        self.volumePath = volumePath
    }
}

extension DiskDescription {
    /// Stable key for per-volume settings: volume UUID, else media UUID, else BSD name.
    public var settingsKey: String { volumeUUID ?? mediaUUID ?? bsdName }
}

public struct Volume: Codable, Equatable, Identifiable, Sendable {
    public var id: String { bsdName }
    public var bsdName: String
    public var wholeDisk: String
    public var label: String
    public var filesystem: FilesystemKind
    public var capacityBytes: Int64
    public var usedBytes: Int64?
    public var mountPoint: String?
    public var access: AccessMode
    public var health: VolumeHealth
    public var mountedBy: MountOwner
    public var deviceModel: String
    public var settingsKey: String
    public var lastError: String?
    /// The backend Driveway mounted this volume with; nil unless Driveway mounted it.
    public var backend: MountBackend?

    public init(
        bsdName: String, wholeDisk: String, label: String, filesystem: FilesystemKind,
        capacityBytes: Int64, usedBytes: Int64?, mountPoint: String?,
        access: AccessMode, health: VolumeHealth, mountedBy: MountOwner,
        deviceModel: String, settingsKey: String, lastError: String?, backend: MountBackend? = nil
    ) {
        self.bsdName = bsdName
        self.wholeDisk = wholeDisk
        self.label = label
        self.filesystem = filesystem
        self.capacityBytes = capacityBytes
        self.usedBytes = usedBytes
        self.mountPoint = mountPoint
        self.access = access
        self.health = health
        self.mountedBy = mountedBy
        self.deviceModel = deviceModel
        self.settingsKey = settingsKey
        self.lastError = lastError
        self.backend = backend
    }
}

public struct SemanticVersion: Comparable, Hashable, Codable, Sendable {
    public var major: Int
    public var minor: Int
    public var patch: Int

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// Parses "5", "5.4" or "5.4.0"; missing components are 0.
    public init?(_ s: String) {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard let n = Int(part), n >= 0 else { return nil }
            numbers.append(n)
        }
        numbers += Array(repeating: 0, count: 3 - numbers.count)
        self.init(major: numbers[0], minor: numbers[1], patch: numbers[2])
    }

    public static func < (a: SemanticVersion, b: SemanticVersion) -> Bool {
        (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch)
    }
}

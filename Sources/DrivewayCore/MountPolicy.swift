import Foundation

/// Persisted as JSON. Fields are added over time, so decoding tolerates missing keys.
public struct DrivewaySettings: Codable, Equatable, Sendable {
    public var autoMountNTFS: Bool
    public var alwaysReadOnly: Set<String>
    public var allowDiskImagesForTesting: Bool
    /// Set by the helper when FSKit fails on an OS build; not a user setting.
    public var fskitFailedOnOSBuild: String?

    public init(
        autoMountNTFS: Bool = true, alwaysReadOnly: Set<String> = [],
        allowDiskImagesForTesting: Bool = false, fskitFailedOnOSBuild: String? = nil
    ) {
        self.autoMountNTFS = autoMountNTFS
        self.alwaysReadOnly = alwaysReadOnly
        self.allowDiskImagesForTesting = allowDiskImagesForTesting
        self.fskitFailedOnOSBuild = fskitFailedOnOSBuild
    }

    private enum CodingKeys: String, CodingKey {
        case autoMountNTFS, alwaysReadOnly, allowDiskImagesForTesting, fskitFailedOnOSBuild
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        autoMountNTFS = try c.decodeIfPresent(Bool.self, forKey: .autoMountNTFS) ?? true
        alwaysReadOnly = try c.decodeIfPresent(Set<String>.self, forKey: .alwaysReadOnly) ?? []
        allowDiskImagesForTesting = try c.decodeIfPresent(Bool.self, forKey: .allowDiskImagesForTesting) ?? false
        fskitFailedOnOSBuild = try c.decodeIfPresent(String.self, forKey: .fskitFailedOnOSBuild)
    }
}

public enum MountAction: Equatable, Sendable {
    case leaveToMacOS, mountNTFSReadWrite, mountExtReadOnly
    case backOff(driver: String)
}

public struct ConsoleUser: Equatable, Sendable {
    public var uid: UInt32
    public var gid: UInt32

    public init(uid: UInt32, gid: UInt32) {
        self.uid = uid
        self.gid = gid
    }
}

/// What the helper does when a drive appears. Rule order: another driver owns it (back off);
/// no console user (leave to macOS, never mount owned by root); NTFS; ext; everything else.
public func autoMountAction(
    filesystem: FilesystemKind, mountedBy: MountOwner, settingsKey: String,
    settings: DrivewaySettings, features: [Feature: FeatureState], consoleUser: ConsoleUser?
) -> MountAction {
    if case .otherDriver(let driver) = mountedBy { return .backOff(driver: driver) }
    let reason = autoMountLeaveReason(
        filesystem: filesystem, settingsKey: settingsKey, settings: settings, features: features, consoleUser: consoleUser)
    if reason != nil { return .leaveToMacOS }
    return filesystem == .ntfs ? .mountNTFSReadWrite : .mountExtReadOnly
}

/// Why the helper leaves a drive to macOS instead of mounting it itself. Logged with each decision.
public enum LeaveReason: Equatable, Sendable, CustomStringConvertible {
    case nobodyLoggedIn
    case notDrivewayFilesystem(FilesystemKind)
    case autoMountOff
    case alwaysReadOnly
    case featureNotReady(Feature, FeatureState?)

    public var description: String {
        switch self {
        case .nobodyLoggedIn: "nobody is logged in"
        case .notDrivewayFilesystem(let fs): "Driveway doesn't mount \(fs.displayName) drives"
        case .autoMountOff: "auto-mount is off"
        case .alwaysReadOnly: "the drive is set to always mount read-only"
        case .featureNotReady(let feature, let state): "\(feature.rawValue) is not ready (\(Self.describe(state)))"
        }
    }

    private static func describe(_ state: FeatureState?) -> String {
        switch state {
        case nil: "unknown"
        case .ready?: "ready"
        case .notAvailableYet?: "not available on this Mac yet"
        case .locked(let missing)?: "locked: " + missing.map(describe).joined(separator: ", ")
        }
    }

    private static func describe(_ r: Requirement) -> String {
        switch r {
        case .macFUSEUpdate(let v): "macFUSEUpdate(\(v.major).\(v.minor).\(v.patch))"
        case .macFUSEApproval(let backend): "macFUSEApproval(\(backend.rawValue))"
        default: "\(r)"
        }
    }
}

/// Why `autoMountAction` leaves a drive that no other driver owns to macOS; nil when Driveway mounts it.
public func autoMountLeaveReason(
    filesystem: FilesystemKind, settingsKey: String, settings: DrivewaySettings, features: [Feature: FeatureState],
    consoleUser: ConsoleUser?
) -> LeaveReason? {
    guard consoleUser != nil else { return .nobodyLoggedIn }
    switch filesystem {
    case .ntfs:
        if !settings.autoMountNTFS { return .autoMountOff }
        if settings.alwaysReadOnly.contains(settingsKey) { return .alwaysReadOnly }
        if features[.writeNTFS] != .ready { return .featureNotReady(.writeNTFS, features[.writeNTFS]) }
        return nil
    case .ext2, .ext3, .ext4:
        return features[.extDrives] == .ready ? nil : .featureNotReady(.extDrives, features[.extDrives])
    case .exfat, .fat32, .fat16, .other:
        return .notDrivewayFilesystem(filesystem)
    }
}

/// Health and reason to record when an NTFS mount ends up read-only (or fails).
public func readOnlyFallback(after outcome: NTFSMountOutcome) -> (health: VolumeHealth, reason: String?) {
    switch outcome {
    case .mounted: (.clean, nil)
    case .dirty: (.dirty, nil)
    case .hibernated: (.hibernated, nil)
    case .notNTFS: (.unknown, "ntfs-3g says this isn't an NTFS volume.")
    case .corrupt: (.unknown, "ntfs-3g says this NTFS volume is damaged. Run chkdsk /f on Windows.")
    case .failed(let message): (.unknown, message)
    }
}

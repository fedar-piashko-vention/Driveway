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
    guard consoleUser != nil else { return .leaveToMacOS }

    switch filesystem {
    case .ntfs:
        if !settings.autoMountNTFS
            || settings.alwaysReadOnly.contains(settingsKey)
            || features[.writeNTFS] != .ready
        {
            return .leaveToMacOS
        }
        return .mountNTFSReadWrite
    case .ext2, .ext3, .ext4:
        return features[.extDrives] == .ready ? .mountExtReadOnly : .leaveToMacOS
    case .exfat, .fat32, .fat16, .other:
        return .leaveToMacOS
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

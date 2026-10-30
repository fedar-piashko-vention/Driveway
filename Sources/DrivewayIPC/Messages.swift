import DrivewayCore

/// A request from the app (or agent) to the root helper. Sent as JSON over XPC.
public enum HelperRequest: Codable, Equatable, Sendable {
    case listVolumes
    case mount(String)
    case unmount(String)
    case eject(String)
    case fixAndMount(String)
    case check(String)
    case repair(String, force: Bool)
    case backup(String, imagePath: String)
    case format(FormatRequest)
    case getSettings
    case setSettings(DrivewaySettings)
    case helperVersion
    case backendStatus

    /// True for the operations that write repair data or erase: they need a fresh administrator authorization.
    public var requiresAuthorization: Bool {
        switch self {
        case .fixAndMount, .repair, .backup, .format: true
        case .listVolumes, .mount, .unmount, .eject, .check, .getSettings, .setSettings, .helperVersion,
            .backendStatus:
            false
        }
    }
}

public enum HelperError: Error, Codable, Equatable, Sendable {
    case protectedDisk
    case notAuthorized
    case unknownVolume
    case toolMissing(String)
    case commandFailed(String)
    case validation(FormatValidationError)
}

public enum HelperResponse: Codable, Equatable, Sendable {
    case volumes([Volume])
    case volume(Volume?)
    case report(CheckReport)
    case settings(DrivewaySettings)
    case version(String)
    case backend(BackendAvailability)
    case ok
    case error(HelperError)
}

/// Why an NTFS volume ended up mounted read-only by macOS instead of read/write by Driveway.
public enum ReadOnlyReason: Codable, Equatable, Sendable {
    case dirty, hibernated
    case error(String)
}

/// Pushed from the helper to connected clients when a drive changes.
public enum VolumeEvent: Codable, Equatable, Sendable {
    case mounted(Volume)
    case mountedReadOnly(Volume, reason: ReadOnlyReason)
    case backedOff(Volume, driver: String)
    case mountFailed(Volume, message: String)
    case removed(bsdName: String)
}

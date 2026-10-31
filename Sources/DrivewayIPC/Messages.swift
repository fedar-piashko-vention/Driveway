import DrivewayCore

/// The drive a request is about: its BSD name, and the identity the app showed for it. BSD names are reused by
/// the next drive plugged in, so the helper refuses a request whose drive is no longer the one the user saw.
public struct DiskRef: Codable, Equatable, Sendable {
    public var bsdName: String
    /// The volume's `settingsKey` as the app showed it.
    public var key: String

    public init(bsdName: String, key: String) {
        self.bsdName = bsdName
        self.key = key
    }

    public init(_ volume: Volume) {
        self.init(bsdName: volume.bsdName, key: volume.settingsKey)
    }
}

/// A request from the app (or agent) to the root helper. Sent as JSON over XPC.
public enum HelperRequest: Codable, Equatable, Sendable {
    case listVolumes
    case mount(DiskRef)
    case unmount(DiskRef)
    case eject(DiskRef)
    case fixAndMount(DiskRef)
    case check(DiskRef)
    case repair(DiskRef, force: Bool)
    case backup(DiskRef, imagePath: String)
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

/// A long drive operation whose tool reports how far it has got.
public enum ProgressOperation: String, Codable, Sendable {
    case check, repair, backup
}

/// Pushed from the helper to connected clients when a drive changes.
public enum VolumeEvent: Codable, Equatable, Sendable {
    case mounted(Volume)
    case mountedReadOnly(Volume, reason: ReadOnlyReason)
    case backedOff(Volume, driver: String)
    case mountFailed(Volume, message: String)
    case removed(bsdName: String)
    /// How much of `operation` on the drive is done, 0...1. Sent about twice a second while it runs; the drive
    /// itself hasn't changed.
    case progress(bsdName: String, operation: ProgressOperation, fraction: Double)
}

extension ReadOnlyReason {
    /// The `VolumeHealth` and error text that `NotificationContent.readOnly` takes for this reason.
    public var healthAndError: (health: VolumeHealth, error: String?) {
        switch self {
        case .dirty: (.dirty, nil)
        case .hibernated: (.hibernated, nil)
        case .error(let message): (.unknown, message)
        }
    }
}

extension VolumeEvent {
    /// The selected BSD name after this event: a drive that was removed is no longer selected, so a later drive
    /// that gets the same BSD name isn't shown, or acted on, in its place.
    public func selection(after current: String?) -> String? {
        if case .removed(let bsdName) = self, bsdName == current { return nil }
        return current
    }

    /// The volume list after this event: a volume carried by the event replaces the one with the same BSD name, or is
    /// appended; `removed` drops it.
    public func applied(to volumes: [Volume]) -> [Volume] {
        let updated: Volume
        switch self {
        case .removed(let bsdName):
            return volumes.filter { $0.bsdName != bsdName }
        case .progress:
            return volumes
        case .mounted(let v), .mountedReadOnly(let v, _), .backedOff(let v, _), .mountFailed(let v, _):
            updated = v
        }
        var result = volumes
        if let index = result.firstIndex(where: { $0.bsdName == updated.bsdName }) {
            result[index] = updated
        } else {
            result.append(updated)
        }
        return result
    }
}

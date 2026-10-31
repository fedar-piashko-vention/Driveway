import Foundation

/// Why a drive's Info tab shows a banner above its details.
public enum VolumeBanner: Equatable, Sendable {
    case dirty, hibernated
    case otherDriver(String)
    case error(String)
}

/// Pure presentation rules for the Disk Manager's drive list and Info tab.
public enum VolumeList {
    public static let managedTitle = "NTFS / ext"
    public static let otherTitle = "Other"

    /// Drives Driveway mounts (NTFS, ext) first, then the ones macOS handles. Empty sections are left out; the order
    /// within a section is the order given.
    public static func sections(_ v: [Volume]) -> [(title: String, volumes: [Volume])] {
        let managed = v.filter { $0.filesystem.isDrivewayManaged }
        let other = v.filter { !$0.filesystem.isDrivewayManaged }
        return [(managedTitle, managed), (otherTitle, other)].filter { !$0.1.isEmpty }
    }

    public static func healthText(_ h: VolumeHealth) -> String {
        switch h {
        case .clean: "Clean"
        case .dirty: "Dirty — not shut down cleanly"
        case .hibernated: "Windows is hibernating"
        case .unknown: "Unknown"
        }
    }

    /// Another driver owning the drive outranks everything else, since Driveway leaves such drives alone. Dirty and
    /// hibernated apply to NTFS only (Fix & mount runs ntfsfix); any other mount error is shown as is.
    public static func banner(for v: Volume) -> VolumeBanner? {
        if case .otherDriver(let driver) = v.mountedBy { return .otherDriver(driver) }
        if v.filesystem == .ntfs {
            switch v.health {
            case .dirty: return .dirty
            case .hibernated: return .hibernated
            case .clean, .unknown: break
            }
        }
        if let error = v.lastError { return .error(error) }
        return nil
    }

    /// The BSD name in a `driveway://volume/<bsd>` link (from a notification), or nil for any other URL.
    public static func bsdName(from url: URL) -> String? {
        guard url.scheme == "driveway", url.host() == "volume" else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count == 1, let bsd = parts.first, !bsd.isEmpty else { return nil }
        return bsd
    }
}

/// Decides whether a refresh's replies may replace the model's state. A refresh is slow next to the events and
/// setting changes that arrive while it runs, so its volume list is dropped if an event was applied meanwhile, and its
/// settings are dropped if a settings write started or finished meanwhile, or is still pending.
public struct RefreshGate: Sendable {
    public struct Token: Equatable, Sendable {
        fileprivate let volumes: Int
        fileprivate let settings: Int
    }

    private var volumesGeneration = 0
    private var settingsGeneration = 0
    private var pendingSettingsWrites = 0

    public init() {}

    public func beginRefresh() -> Token {
        Token(volumes: volumesGeneration, settings: settingsGeneration)
    }

    public mutating func eventApplied() {
        volumesGeneration += 1
    }

    public mutating func settingsWriteStarted() {
        settingsGeneration += 1
        pendingSettingsWrites += 1
    }

    public mutating func settingsWriteFinished() {
        settingsGeneration += 1
        pendingSettingsWrites = max(0, pendingSettingsWrites - 1)
    }

    public func acceptsVolumes(from token: Token) -> Bool {
        token.volumes == volumesGeneration
    }

    public func acceptsSettings(from token: Token) -> Bool {
        pendingSettingsWrites == 0 && token.settings == settingsGeneration
    }
}

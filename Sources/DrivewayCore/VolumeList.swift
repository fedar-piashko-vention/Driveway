import Foundation

/// Why a drive's Info tab shows a banner above its details.
public enum VolumeBanner: Equatable, Sendable {
    case dirty, hibernated
    case otherDriver(String)
    case error(String)
}

/// What the Check & Repair tab can do for a drive.
public enum RepairAction: Equatable, Sendable {
    case check, backupFirst, repair, repairForce
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

    /// The Info tab offers Mount read/write for an NTFS drive that macOS mounted (read-only) or that isn't mounted,
    /// unless it is dirty or hibernated: those have their own banner, and mounting again can't help.
    public static func offersMountReadWrite(_ v: Volume) -> Bool {
        guard v.filesystem == .ntfs, v.health != .dirty, v.health != .hibernated else { return false }
        return v.mountedBy == .macOS || v.mountedBy == .none
    }

    /// What to tell the user when Mount read/write didn't end with Driveway's read/write mount; nil when it did.
    public static func mountReadWriteProblem(_ v: Volume) -> String? {
        if v.mountedBy == .driveway, v.access == .readWrite { return nil }
        let failed = "Driveway couldn't mount this drive read/write"
        if let error = v.lastError { return "\(failed): \(error)" }
        switch v.health {
        case .dirty: return "\(failed) because Windows didn't shut it down cleanly. Use \(Copy.fixAndMount)."
        case .hibernated:
            return "\(failed) because Windows is hibernating. Shut Windows down fully, then plug the drive in again."
        case .clean, .unknown: return "\(failed). Open Setup to check that NTFS writing is ready."
        }
    }

    /// The buttons the Check & Repair tab offers. Back up is NTFS only (the helper clones with ntfsclone); the forced
    /// repair answers yes to everything (`e2fsck -y`), so only ext has it.
    public static func repairActions(for fs: FilesystemKind) -> [RepairAction] {
        switch fs {
        case .ntfs: [.check, .backupFirst, .repair]
        case .ext2, .ext3, .ext4: [.check, .repair, .repairForce]
        case .exfat, .fat32, .fat16: [.check, .repair]
        case .other: []
        }
    }

    /// The note shown next to the repair buttons.
    public static func repairNote(for fs: FilesystemKind) -> String? {
        fs == .ntfs ? Copy.ntfsRepairNote : nil
    }

    /// The save panel's default name, `<label>-<yyyy-MM-dd>.img`. The date is the user's local one, formatted in a
    /// fixed locale so it never turns into other digits or calendars. A label can't hold a path separator.
    public static func backupFileName(label: String, date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        let safe = String(label.map { $0 == "/" || $0 == ":" ? "-" : $0 })
        return "\(safe.isEmpty ? "Drive" : safe)-\(formatter.string(from: date)).img"
    }

    /// True when `path` is the mount point or inside it. Whole components are compared, ignoring case (macOS volumes
    /// are usually case-insensitive), so "/Volumes/Data 2/x" is not inside "/Volumes/Data". Both paths should already
    /// be standardized.
    public static func isInside(path: String, mountPoint: String?) -> Bool {
        guard let mountPoint, !mountPoint.isEmpty else { return false }
        func components(_ p: String) -> [String] { URL(fileURLWithPath: p).pathComponents.map { $0.lowercased() } }
        let root = components(mountPoint)
        let target = components(path)
        return target.count >= root.count && Array(target.prefix(root.count)) == root
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

import Foundation

/// User-facing strings. No copy here may suggest lowering macOS security.
public enum Copy {
    public static let unlock = "Unlock"
    public static let unlockEverything = "Unlock everything"
    public static let needsApproval = "Needs approval"
    public static let openSettings = "Open Settings"
    public static let notAvailableOnThisMac = "Not available on this Mac yet"
    public static let noBackendReason =
        "macFUSE can't mount drives on this macOS version with your Mac's security settings. Driveway checks again after each macOS or macFUSE update."

    public static let forOlderPCs = "for older PCs"

    public static func featuresReady(_ n: Int) -> String { "\(n) of 4 features ready" }

    public static let fixAndMount = "Fix & mount read/write"
    public static let handledByMacOS = "handled by macOS"
    public static func mountedBy(_ driver: String) -> String { "Mounted by \(driver)" }
    public static let autoMountNTFS = "Auto-mount NTFS read/write"
    public static let alwaysMountReadOnly = "Always mount read-only"

    public static let backUpFirst = "Back up first"
    public static let ntfsRepairNote =
        "This fixes common issues (unclean eject, journal), not deep damage. For real damage, connect the drive to Windows and run chkdsk /f."
}

/// What a user notification says and where clicking it goes. Built from core values so Core stays independent of IPC.
public struct NotificationContent: Equatable, Sendable {
    public var title: String
    public var body: String
    /// Where a click goes. Nil means "just open Driveway".
    public var openURL: URL?

    public init(title: String, body: String, openURL: URL?) {
        self.title = title
        self.body = body
        self.openURL = openURL
    }

    private static let title = "Driveway"

    /// A drive mounted read-only. Dirty and hibernated drives have fixed copy; any other health is reported with the
    /// error that stopped the read/write mount.
    public static func readOnly(label: String, bsdName: String, health: VolumeHealth, error: String?) -> NotificationContent {
        let body: String
        switch health {
        case .dirty:
            body = "\(label) was mounted read-only because Windows didn't shut it down cleanly — click to fix"
        case .hibernated:
            body =
                "\(label) was mounted read-only because Windows is hibernating (Fast Startup). Shut Windows down fully, then plug the drive in again."
        case .clean, .unknown:
            body =
                "\(label) was mounted read-only because Driveway couldn't mount it read/write: \(error ?? "unknown error") — click to fix"
        }
        return NotificationContent(title: title, body: body, openURL: URL(string: "driveway://volume/\(bsdName)"))
    }

    /// Another driver (Tuxera, Paragon) owns the drive, so Driveway stepped aside.
    public static func backedOff(label: String, driver: String) -> NotificationContent {
        NotificationContent(
            title: title, body: "\(label) was mounted by \(driver), so Driveway left it alone.", openURL: nil)
    }

    public static func mountFailed(label: String, message: String) -> NotificationContent {
        NotificationContent(title: title, body: "Driveway couldn't mount \(label): \(message)", openURL: nil)
    }
}

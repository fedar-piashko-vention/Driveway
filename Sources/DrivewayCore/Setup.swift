import Foundation

extension BackendPolicy {
    /// The backend the app assumes before the helper can answer (`bputil -d` needs root). A loaded macFUSE kext means
    /// kernel; otherwise an enabled FSKit module means FSKit. With neither signal the app can't tell which backend
    /// this Mac needs, so it assumes kernel as a placeholder that locks nothing: the helper requirement is still
    /// listed, and the scan after installing the helper gives the real answer. Nil outputs mean the tool failed.
    public static func availabilityWithoutHelper(kmutilOutput: String?, pluginkitOutput: String?) -> BackendAvailability {
        if let kmutilOutput, MacFUSEProbe.kextLoaded(kmutilOutput: kmutilOutput) { return .ready(.kernel) }
        if let pluginkitOutput, MacFUSEProbe.isApproved(pluginkitOutput: pluginkitOutput) { return .ready(.fskit) }
        return .ready(.kernel)
    }
}

extension InstallStep {
    /// True when the step hands over to something outside Driveway (a web page, Terminal, System Settings), so the
    /// steps after it have to wait until the user comes back.
    public var continuesOutsideDriveway: Bool {
        switch self {
        case .openURL, .runInTerminal, .openSettings: true
        case .runBrew, .installHelper: false
        }
    }
}

extension ConflictingDrivers {
    /// The vendor's support page, which explains how to uninstall the driver.
    public static func supportURL(for driver: String) -> URL? {
        if driver.hasPrefix("Tuxera") { return URL(string: "https://www.tuxera.com/support/") }
        if driver.hasPrefix("Paragon") { return URL(string: "https://www.paragon-software.com/support/") }
        return nil
    }
}

/// One missing requirement in a Setup group.
public struct SetupItem: Equatable, Sendable {
    public var requirement: Requirement
    public var label: String
    /// ⚠️ for something to approve or update, ❌ for something to install.
    public var symbol: String
}

/// One feature on the Setup screen (mockup B): its state and what it still needs.
public struct SetupGroup: Equatable, Sendable, Identifiable {
    public var feature: Feature
    public var title: String
    /// A line under the title: "Built into macOS", or why the feature isn't available.
    public var detail: String?
    public var state: FeatureState
    public var items: [SetupItem]
    public var id: Feature { feature }
}

/// What the Setup screen shows and the order its Unlock buttons install things in.
public enum SetupScreen {
    public static func groups(_ states: [Feature: FeatureState]) -> [SetupGroup] {
        Feature.allCases.map { feature in
            let state = states[feature] ?? .locked(missing: [])
            var detail: String?
            var items: [SetupItem] = []
            switch state {
            case .ready:
                if feature == .readNTFS { detail = "Built into macOS" }
            case .notAvailableYet:
                detail = "\(Copy.notAvailableOnThisMac). \(Copy.noBackendReason)"
            case .locked(let missing):
                items = missing.map {
                    SetupItem(requirement: $0, label: Copy.requirementLabel($0), symbol: isWarning($0) ? "⚠️" : "❌")
                }
            }
            return SetupGroup(feature: feature, title: title(feature), detail: detail, state: state, items: items)
        }
    }

    public static func readyFeatures(_ states: [Feature: FeatureState]) -> Set<Feature> {
        Set(states.filter { $0.value == .ready }.keys)
    }

    /// The missing requirements of the given features, in each feature's requirement order and then feature order,
    /// each once. The helper comes last, so it starts with the tools already in place, and Full Disk Access after
    /// it: it is granted to the installed helper.
    public static func unlockOrder(for features: [Feature], in states: [Feature: FeatureState]) -> [Requirement] {
        var order: [Requirement] = []
        for feature in Feature.allCases where features.contains(feature) {
            guard case .locked(let missing)? = states[feature] else { continue }
            for requirement in missing where !order.contains(requirement) { order.append(requirement) }
        }
        let isHelper: (Requirement) -> Bool = { $0 == .helper || $0 == .helperUpdate }
        let isAccess: (Requirement) -> Bool = { $0 == .fullDiskAccess }
        return order.filter { !isHelper($0) && !isAccess($0) } + order.filter(isHelper) + order.filter(isAccess)
    }

    /// The requirements to act on now: up to and including the first one that continues outside Driveway.
    public static func runNow(_ order: [Requirement]) -> [Requirement] {
        guard let handoff = order.firstIndex(where: { InstallStep.for($0).continuesOutsideDriveway }) else { return order }
        return Array(order[...handoff])
    }

    /// "Open Settings" when the next thing to do is an approval in System Settings, otherwise "Unlock".
    public static func buttonTitle(for order: [Requirement]) -> String {
        switch order.first {
        case .macFUSEApproval?, .fullDiskAccess?: return Copy.openSettings
        default: return Copy.unlock
        }
    }

    private static func title(_ feature: Feature) -> String {
        switch feature {
        case .readNTFS: "Read NTFS drives"
        case .writeNTFS: "Write to NTFS drives"
        case .repairNTFS: "Check & Repair NTFS"
        case .extDrives: "ext drives (optional)"
        }
    }

    private static func isWarning(_ r: Requirement) -> Bool {
        switch r {
        case .macFUSEUpdate, .macFUSEApproval, .helperUpdate, .fullDiskAccess: true
        case .homebrew, .macFUSE, .ntfs3g, .ext4fuse, .e2fsprogs, .helper: false
        }
    }
}

extension Copy {
    public static let moveToApplications = "Move Driveway to Applications first"
    public static let untrustedTapNote =
        "ntfs-3g and ext4fuse come from gromgit/fuse, a community tap that Homebrew marks as untrusted. If Homebrew asks whether to continue, Continue answers yes."

    public static func requirementLabel(_ r: Requirement) -> String {
        switch r {
        case .homebrew: "Homebrew"
        case .macFUSE: "macFUSE 5.4 or later"
        case .macFUSEUpdate(let v): "macFUSE \(v.major).\(v.minor).\(v.patch) — needs update to 5.4 or later"
        case .macFUSEApproval(.kernel): "macFUSE — needs approval in System Settings → Privacy & Security"
        case .macFUSEApproval(.fskit): "macFUSE — needs approval in System Settings → General → Login Items & Extensions"
        case .ntfs3g: "ntfs-3g"
        case .ext4fuse: "ext4fuse"
        case .e2fsprogs: "e2fsprogs"
        case .helper: "Driveway helper"
        case .helperUpdate: "Driveway helper — needs update"
        case .fullDiskAccess: "Driveway helper — needs Full Disk Access in System Settings → Privacy & Security"
        }
    }

    /// What to do after a step that continues outside Driveway; nil for steps Driveway finishes itself.
    public static func afterHandoff(_ r: Requirement) -> String? {
        switch r {
        case .homebrew:
            "Install Homebrew with the instructions on brew.sh, then click Unlock again."
        case .macFUSE, .macFUSEUpdate:
            "Finish installing macFUSE in Terminal (it asks for your password), then click Unlock again."
        case .macFUSEApproval(.kernel):
            "Allow macFUSE in System Settings → Privacy & Security. macOS may ask you to restart. Driveway checks again when you come back."
        case .macFUSEApproval(.fskit):
            "Turn on macFUSE in System Settings → General → Login Items & Extensions → File System Extensions. Driveway checks again when you come back."
        case .fullDiskAccess:
            fullDiskAccessSteps
        case .ntfs3g, .ext4fuse, .e2fsprogs, .helper, .helperUpdate:
            nil
        }
    }

    /// A conflict warning row: names the driver and says how to get Driveway mounting those drives.
    public static func conflictWarning(driver: String) -> String {
        let kind = driver.hasSuffix("extFS") ? "ext" : "NTFS"
        return "\(driver) is installed. Driveway leaves drives it mounts alone. Uninstall it to let Driveway mount \(kind) drives."
    }
}

/// Splits a byte stream into lines on `\n` or `\r`, dropping blank lines. Bytes are only decoded once a line is
/// complete, so a UTF-8 character split between chunks stays intact.
public struct LineSplitter: Sendable {
    private var pending: [UInt8] = []

    public init() {}

    /// The complete lines in the bytes received so far.
    public mutating func append(_ data: Data) -> [String] {
        var lines: [String] = []
        for byte in data {
            if byte == 0x0A || byte == 0x0D {
                if !pending.isEmpty { lines.append(String(decoding: pending, as: UTF8.self)) }
                pending.removeAll(keepingCapacity: true)
            } else {
                pending.append(byte)
            }
        }
        return lines
    }

    /// The unfinished last line, e.g. a prompt waiting for an answer.
    public var tail: String { String(decoding: pending, as: UTF8.self) }

    /// The unfinished last line at end of input, if any.
    public mutating func finish() -> String? {
        defer { pending.removeAll() }
        return pending.isEmpty ? nil : String(decoding: pending, as: UTF8.self)
    }
}

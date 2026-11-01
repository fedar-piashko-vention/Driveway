import Foundation

public enum Feature: String, CaseIterable, Codable, Sendable {
    case readNTFS, writeNTFS, repairNTFS, extDrives
}

public enum Requirement: Equatable, Hashable, Sendable {
    case homebrew
    case macFUSE
    case macFUSEUpdate(installed: SemanticVersion)
    case macFUSEApproval(MountBackend)
    case ntfs3g, ext4fuse, e2fsprogs
    case helper, helperUpdate
}

public enum BackendAvailability: Equatable, Codable, Sendable {
    case ready(MountBackend)
    case needsApproval(MountBackend)
    case unavailable
}

public enum BackendPolicy {
    /// Hybrid backend choice: the kernel backend where the Mac already allows third-party kexts,
    /// otherwise FSKit. Never suggests lowering security.
    public static func availability(
        kextsAllowed: Bool, kextApproved: Bool, fskitEnabled: Bool, fskitFailedOnThisOS: Bool
    ) -> BackendAvailability {
        if kextsAllowed { return kextApproved ? .ready(.kernel) : .needsApproval(.kernel) }
        if fskitFailedOnThisOS { return .unavailable }
        return fskitEnabled ? .ready(.fskit) : .needsApproval(.fskit)
    }
}

public struct ToolInventory: Equatable, Sendable {
    public var hasHomebrew: Bool
    public var macFUSEVersion: SemanticVersion?
    public var backend: BackendAvailability
    public var hasNTFS3G: Bool
    public var hasExt4fuse: Bool
    public var hasE2fsprogs: Bool
    public var helperVersion: String?
    public var appVersion: String
    public var conflictingDrivers: [String]

    public init(
        hasHomebrew: Bool, macFUSEVersion: SemanticVersion?, backend: BackendAvailability,
        hasNTFS3G: Bool, hasExt4fuse: Bool, hasE2fsprogs: Bool,
        helperVersion: String?, appVersion: String, conflictingDrivers: [String]
    ) {
        self.hasHomebrew = hasHomebrew
        self.macFUSEVersion = macFUSEVersion
        self.backend = backend
        self.hasNTFS3G = hasNTFS3G
        self.hasExt4fuse = hasExt4fuse
        self.hasE2fsprogs = hasE2fsprogs
        self.helperVersion = helperVersion
        self.appVersion = appVersion
        self.conflictingDrivers = conflictingDrivers
    }
}

public enum FeatureState: Equatable, Sendable {
    case ready
    case locked(missing: [Requirement])
    case notAvailableYet
}

private let minimumMacFUSE = SemanticVersion(major: 5, minor: 4, patch: 0)

private func helperRequirement(_ inv: ToolInventory) -> Requirement? {
    guard let version = inv.helperVersion else { return .helper }
    return version == inv.appVersion ? nil : .helperUpdate
}

public func featureStates(
    _ inv: ToolInventory, ntfsWriteSupported: Bool = Capabilities.ntfsWriteSupported
) -> [Feature: FeatureState] {
    let macFUSEReady = inv.macFUSEVersion.map { $0 >= minimumMacFUSE } ?? false

    func state(macFUSE: Bool, tools: [(missing: Bool, requirement: Requirement)]) -> FeatureState {
        // The backend only matters once a current macFUSE is installed.
        if macFUSE, macFUSEReady, inv.backend == .unavailable { return .notAvailableYet }

        var missing: [Requirement] = []
        if macFUSE {
            if let installed = inv.macFUSEVersion {
                if installed < minimumMacFUSE { missing.append(.macFUSEUpdate(installed: installed)) }
            } else {
                missing.append(.macFUSE)
            }
            if macFUSEReady, case .needsApproval(let backend) = inv.backend {
                missing.append(.macFUSEApproval(backend))
            }
        }
        missing += tools.filter(\.missing).map(\.requirement)

        let brewItemMissing = (macFUSE && !macFUSEReady) || tools.contains { $0.missing }
        if brewItemMissing && !inv.hasHomebrew { missing.insert(.homebrew, at: 0) }
        if let helper = helperRequirement(inv) { missing.append(helper) }
        return missing.isEmpty ? .ready : .locked(missing: missing)
    }

    var states: [Feature: FeatureState] = [.readNTFS: .ready]

    states[.writeNTFS] = ntfsWriteSupported
        ? state(macFUSE: true, tools: [(!inv.hasNTFS3G, .ntfs3g)])
        : .notAvailableYet
    states[.repairNTFS] = state(macFUSE: false, tools: [(!inv.hasNTFS3G, .ntfs3g)])
    states[.extDrives] = state(
        macFUSE: true, tools: [(!inv.hasExt4fuse, .ext4fuse), (!inv.hasE2fsprogs, .e2fsprogs)])
    return states
}

public func readyCount(_ states: [Feature: FeatureState]) -> Int {
    states.values.filter { $0 == .ready }.count
}

public enum ConflictingDrivers {
    private static let bundles: [String: String] = [
        "tuxera_ntfs.fs": "Tuxera NTFS",
        "ufsd_NTFS.fs": "Paragon NTFS",
        "ufsd_ExtFS.fs": "Paragon extFS",
    ]
    private static let volumeKinds: [String: String] = [
        "tuxera_ntfs": "Tuxera NTFS",
        "ufsd_NTFS": "Paragon NTFS",
        "ufsd_ExtFS": "Paragon extFS",
    ]

    /// Names of third-party NTFS/ext drivers found among the installed filesystem bundles, in input order.
    public static func detect(filesystemBundles: [String]) -> [String] {
        var names: [String] = []
        for bundle in filesystemBundles {
            if let name = bundles[bundle], !names.contains(name) { names.append(name) }
        }
        return names
    }

    public static func driverName(forDAVolumeKind kind: String?) -> String? {
        kind.flatMap { volumeKinds[$0] }
    }
}

public enum InstallStep: Equatable, Sendable {
    case openURL(URL)
    case runBrew([String])
    case runInTerminal(String)
    case openSettings(URL)
    case installHelper

    public static func `for`(_ r: Requirement) -> InstallStep {
        switch r {
        case .homebrew: .openURL(URL(string: "https://brew.sh")!)
        case .macFUSE: .runInTerminal("brew install --cask macfuse")
        case .macFUSEUpdate: .runInTerminal("brew upgrade --cask macfuse")
        case .macFUSEApproval(.fskit):
            .openSettings(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
        case .macFUSEApproval(.kernel):
            .openSettings(URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension")!)
        case .ntfs3g: .runBrew(["install", "gromgit/fuse/ntfs-3g-mac"])
        case .ext4fuse: .runBrew(["install", "gromgit/fuse/ext4fuse-mac"])
        case .e2fsprogs: .runBrew(["install", "e2fsprogs"])
        case .helper, .helperUpdate: .installHelper
        }
    }
}

public enum SetupPolicy {
    /// Show Setup on first launch (nothing recorded yet) or when a previously ready feature stopped being ready.
    public static func shouldShowSetup(previouslyReady: Set<Feature>?, nowReady: Set<Feature>) -> Bool {
        guard let previouslyReady else { return true }
        return !previouslyReady.isSubset(of: nowReady)
    }
}

/// Parses the outputs of the tools that tell whether macFUSE's backends may run. Rules and samples are in
/// docs/spike-results.md ("Kernel extension policy" and the FSKit module row).
public enum MacFUSEProbe {
    static let fsModulePrefix = "io.macfuse.app.fsmodule.macfuse"
    static let kextBundlePrefix = "io.macfuse.filesystems.macfuse"
    static let teamID = "3T5GSNBU6W"

    /// `pluginkit -m -v -p com.apple.fskit.fsmodule`: a macFUSE module line whose election marker is blank
    /// or `+`. While enabled, the spike saw a blank first column (not `+`). Any other marker (`-` disabled,
    /// `=`, `!`, ...) is false.
    public static func isApproved(pluginkitOutput: String) -> Bool {
        lines(pluginkitOutput).contains { line in
            var rest = line.drop { $0 == " " || $0 == "\t" }
            if rest.first == "+" { rest = rest.dropFirst().drop { $0 == " " || $0 == "\t" } }
            return rest.hasPrefix(fsModulePrefix)
        }
    }

    /// `kmutil showloaded --list-only` lists macFUSE's kext (`io.macfuse.filesystems.macfuse.23 (5.5.0)`).
    public static func kextLoaded(kmutilOutput: String) -> Bool {
        lines(kmutilOutput).contains { line in
            line.split(whereSeparator: \.isWhitespace).contains { $0.hasPrefix(kextBundlePrefix) }
        }
    }

    /// `bputil -d`: the `3rd Party Kexts Status:` line says `Enabled`. Anything else, or no line, is false.
    public static func kextsAllowed(bputilOutput: String) -> Bool {
        let label = "3rd Party Kexts Status:"
        return lines(bputilOutput).contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(label) else { return false }
            return trimmed.dropFirst(label.count).split(whereSeparator: \.isWhitespace).first == "Enabled"
        }
    }

    /// `sqlite3 -header KextPolicy "select * from kext_policy;"`: pipe-separated rows after a header row.
    /// True when a row has macFUSE's team id, a macFUSE kext bundle id and `allowed` = 1.
    public static func kextApproved(kextPolicyRows: String) -> Bool {
        var rows = lines(kextPolicyRows).map { $0.split(separator: "|", omittingEmptySubsequences: false).map(String.init) }
        guard !rows.isEmpty else { return false }
        let header = rows.removeFirst().map { $0.trimmingCharacters(in: .whitespaces) }
        guard let team = header.firstIndex(of: "team_id"), let bundle = header.firstIndex(of: "bundle_id"),
              let allowed = header.firstIndex(of: "allowed")
        else { return false }
        let needed = max(team, bundle, allowed)
        return rows.contains { row in
            guard row.count > needed else { return false }
            return row[team].trimmingCharacters(in: .whitespaces) == teamID
                && row[bundle].trimmingCharacters(in: .whitespaces).hasPrefix(kextBundlePrefix)
                && row[allowed].trimmingCharacters(in: .whitespaces) == "1"
        }
    }

    private static func lines(_ s: String) -> [Substring] {
        s.split(whereSeparator: \.isNewline).filter { !$0.allSatisfy(\.isWhitespace) }
    }
}

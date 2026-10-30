import Foundation

/// What happened when ntfs-3g tried to mount a volume.
public enum NTFSMountOutcome: Equatable, Sendable {
    case mounted, dirty, hibernated, notNTFS, corrupt
    case failed(String)

    /// Classification order: exit 0 is `.mounted`; exit codes 12-15 map by ntfs-3g's `volume.h`
    /// table (12 not NTFS, 13 corrupt, 14 hibernated, 15 unclean); any other non-zero code is
    /// matched against known stderr phrases (case-insensitive), else `.failed` carries the
    /// trimmed stderr, or "ntfs-3g exited with code N" when stderr is empty.
    public static func classify(exitCode: Int32, stderr: String) -> NTFSMountOutcome {
        if exitCode == 0 { return .mounted }
        switch exitCode {
        case 12: return .notNTFS
        case 13: return .corrupt
        case 14: return .hibernated
        case 15: return .dirty
        default: break
        }
        let lowered = stderr.lowercased()
        if ["windows cache", "hibernat", "fast restart"].contains(where: lowered.contains) {
            return .hibernated
        }
        if ["scheduled for check", "unclean"].contains(where: lowered.contains) {
            return .dirty
        }
        let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return .failed(message.isEmpty ? "ntfs-3g exited with code \(exitCode)" : message)
    }
}

public struct FixStep: Equatable, Sendable {
    public var name: String
    public var ok: Bool

    public init(name: String, ok: Bool) {
        self.name = name
        self.ok = ok
    }
}

/// The parsed result of an `ntfsfix` run.
public struct NTFSFixReport: Equatable, Sendable {
    public var succeeded: Bool
    public var steps: [FixStep]

    public init(succeeded: Bool, steps: [FixStep]) {
        self.succeeded = succeeded
        self.steps = steps
    }

    /// Steps come only from lines whose trimmed text ends with "... OK" or "... FAILED"; the
    /// name is the text before the "...". `succeeded` needs "processed successfully" in the
    /// output and no failed step.
    public static func parse(_ output: String) -> NTFSFixReport {
        var steps: [FixStep] = []
        for line in output.split(whereSeparator: \.isNewline) {
            let text = line.trimmingCharacters(in: .whitespaces)
            let ok: Bool
            let suffix: String
            if text.hasSuffix("... OK") {
                ok = true
                suffix = "... OK"
            } else if text.hasSuffix("... FAILED") {
                ok = false
                suffix = "... FAILED"
            } else {
                continue
            }
            let name = String(text.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
            steps.append(FixStep(name: name, ok: ok))
        }
        let succeeded = output.contains("processed successfully") && steps.allSatisfy(\.ok)
        return NTFSFixReport(succeeded: succeeded, steps: steps)
    }
}

public enum E2fsckOutcome: Equatable, Sendable {
    case clean, corrected, correctedNeedsReboot, uncorrected, operationalError, cancelled

    /// e2fsck's exit code is a bitmask. Precedence: bits 8 or 16 (operational or usage error)
    /// win, then 32 (cancelled), then 4 (errors left uncorrected), 2 (corrected, reboot needed)
    /// and 1 (corrected).
    public static func from(exitCode: Int32) -> E2fsckOutcome {
        if exitCode & (8 | 16) != 0 { return .operationalError }
        if exitCode & 32 != 0 { return .cancelled }
        if exitCode & 4 != 0 { return .uncorrected }
        if exitCode & 2 != 0 { return .correctedNeedsReboot }
        if exitCode & 1 != 0 { return .corrected }
        return .clean
    }
}

public struct CheckReport: Codable, Equatable, Sendable {
    public var filesystem: FilesystemKind
    public var mode: CheckMode
    public var succeeded: Bool
    public var summary: String
    public var rawOutput: String

    public init(filesystem: FilesystemKind, mode: CheckMode, succeeded: Bool, summary: String, rawOutput: String) {
        self.filesystem = filesystem
        self.mode = mode
        self.succeeded = succeeded
        self.summary = summary
        self.rawOutput = rawOutput
    }
}

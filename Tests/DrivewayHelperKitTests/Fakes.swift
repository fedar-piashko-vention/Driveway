import DrivewayCore
import DrivewayHelperKit
import DrivewayIPC
import Foundation
import Synchronization

/// Records every command and returns scripted results keyed by executable + first argument.
/// Unscripted commands exit 0 with empty output.
final class FakeRunner: CommandRunning {
    private struct State {
        var commands: [Command] = []
        var results: [String: CommandResult] = [:]
        var errors: [String: any Error & Sendable] = [:]
        var onRun: (@Sendable (Command) -> Void)?
    }
    private let state = Mutex(State())

    var commands: [Command] { state.withLock { $0.commands } }

    private static func key(_ executable: String, _ firstArgument: String?) -> String {
        "\(executable) \(firstArgument ?? "")"
    }

    func script(_ executable: String, _ firstArgument: String, exit: Int32, stdout: String = "", stderr: String = "") {
        state.withLock {
            $0.results[Self.key(executable, firstArgument)] = CommandResult(exitCode: exit, stdout: stdout, stderr: stderr)
        }
    }

    func fail(_ executable: String, _ firstArgument: String, with error: any Error & Sendable) {
        state.withLock { $0.errors[Self.key(executable, firstArgument)] = error }
    }

    /// Called after a command is recorded and before its result is returned.
    func onRun(_ body: @escaping @Sendable (Command) -> Void) {
        state.withLock { $0.onRun = body }
    }

    func run(_ c: Command) async throws -> CommandResult {
        let (result, error, hook) = state.withLock { s in
            s.commands.append(c)
            let k = Self.key(c.executable, c.arguments.first)
            return (s.results[k], s.errors[k], s.onRun)
        }
        hook?(c)
        if let error { throw error }
        return result ?? CommandResult(exitCode: 0, stdout: "", stderr: "")
    }
}

struct FakeAuth: AuthorizationVerifying {
    var valid: Bool
    init(valid: Bool) { self.valid = valid }
    func verify(_ externalForm: Data?, right: String) -> Bool {
        valid && right == AuthorizationRights.modifyDisk
    }
}

final class FakeInventory: DiskInventoryProviding {
    private struct State {
        var disks: [DiskDescription]
        var headers: [String: Data]
        var boot: Set<String>
        var mounted: Bool
        var headerReads: [String] = []
        var mountChecks: [String] = []
    }
    private let state: Mutex<State>

    init(disks: [DiskDescription], headers: [String: Data] = [:], boot: Set<String> = ["disk0"], mounted: Bool = true) {
        state = Mutex(State(disks: disks, headers: headers, boot: boot, mounted: mounted))
    }

    func setDisks(_ disks: [DiskDescription]) { state.withLock { $0.disks = disks } }
    var headerReads: [String] { state.withLock { $0.headerReads } }
    var mountChecks: [String] { state.withLock { $0.mountChecks } }

    func disks() async -> [DiskDescription] { state.withLock { $0.disks } }

    func header(of bsdName: String) async throws -> Data {
        try state.withLock { s in
            s.headerReads.append(bsdName)
            guard let h = s.headers[bsdName] else { throw CocoaError(.fileReadNoSuchFile) }
            return h
        }
    }

    func bootWholeDisks() async -> Set<String> { state.withLock { $0.boot } }
    func usage(ofMountPoint: String) -> Int64? { 1_000 }

    func isMounted(at mountPoint: String) async -> Bool {
        state.withLock { s in
            s.mountChecks.append(mountPoint)
            return s.mounted
        }
    }
}

final class MemorySettings: SettingsStoring {
    private let state: Mutex<DrivewaySettings>
    init(_ s: DrivewaySettings = DrivewaySettings()) { state = Mutex(s) }
    var current: DrivewaySettings { state.withLock { $0 } }
    func load() -> DrivewaySettings { state.withLock { $0 } }
    func save(_ s: DrivewaySettings) throws { state.withLock { $0 = s } }
}

struct FakeProbe: BackendProbing {
    var kextsAllowed: Bool
    var kextApproved: Bool
    var fskitEnabled: Bool

    static let kernel = FakeProbe(kextsAllowed: true, kextApproved: true, fskitEnabled: false)
    static let fskit = FakeProbe(kextsAllowed: false, kextApproved: false, fskitEnabled: true)
    static let none = FakeProbe(kextsAllowed: false, kextApproved: false, fskitEnabled: false)

    func probe() async -> (kextsAllowed: Bool, kextApproved: Bool, fskitEnabled: Bool) {
        (kextsAllowed, kextApproved, fskitEnabled)
    }
}

// MARK: - Sample data

let tools = ToolPaths()
let diskutil = "/usr/sbin/diskutil"
let osBuild = "24G84"
let allReady: [Feature: FeatureState] = [.readNTFS: .ready, .writeNTFS: .ready, .repairNTFS: .ready, .extDrives: .ready]

func disk(
    _ bsd: String, whole: String? = nil, wholeMedia: Bool = false, kind: String? = "ntfs", type: String? = nil,
    content: String? = "Microsoft Basic Data", name: String? = "BACKUP", path: String? = nil,
    size: Int64 = 620_000_000_000, image: Bool = false
) -> DiskDescription {
    DiskDescription(
        bsdName: bsd, wholeDisk: whole ?? wholeDiskName(bsd) ?? bsd, isWholeMedia: wholeMedia, isInternal: false,
        isDiskImage: image, volumeKind: kind, volumeType: type, contentType: content, volumeName: name,
        volumeUUID: "UUID-\(bsd)", mediaUUID: nil, sizeBytes: size, deviceModel: "Portable SSD", volumePath: path)
}

/// "disk4s1" -> "disk4", "disk4" -> "disk4".
func wholeDiskName(_ bsd: String) -> String? {
    guard bsd.hasPrefix("disk") else { return nil }
    return "disk" + bsd.dropFirst(4).prefix(while: \.isNumber)
}

let ntfsHeader = Data([0xEB, 0x52, 0x90] + Array("NTFS    ".utf8) + [UInt8](repeating: 0, count: 501))

/// A minimal ext4 superblock region: magic 0xEF53 at 1080 and the extents incompat flag at 1120.
let ext4Header: Data = {
    var b = [UInt8](repeating: 0, count: 2048)
    b[1080] = 0x53
    b[1081] = 0xEF
    b[1120] = 0x40
    return Data(b)
}()

struct Harness {
    let service: HelperService
    let runner: FakeRunner
    let inventory: FakeInventory
    let settings: MemorySettings
}

func makeHarness(
    disks: [DiskDescription], headers: [String: Data] = [:], auth: Bool = true, probe: FakeProbe = .kernel,
    settings: DrivewaySettings = DrivewaySettings(), console: ConsoleUser? = ConsoleUser(uid: 501, gid: 20),
    features: [Feature: FeatureState] = allReady, boot: Set<String> = ["disk0"], mounted: Bool = true,
    consoleProvider: (@Sendable () -> ConsoleUser?)? = nil
) -> Harness {
    let runner = FakeRunner()
    let inventory = FakeInventory(disks: disks, headers: headers, boot: boot, mounted: mounted)
    let store = MemorySettings(settings)
    let service = HelperService(
        runner: runner, auth: FakeAuth(valid: auth), inventory: inventory, settings: store, paths: tools,
        backendProbe: probe, osBuild: osBuild, consoleUser: consoleProvider ?? { console }, features: { features })
    return Harness(service: service, runner: runner, inventory: inventory, settings: store)
}

func cmd(_ executable: String, _ args: String...) -> Command { Command(executable: executable, arguments: args) }

final class ConsoleBox: Sendable {
    private let state: Mutex<ConsoleUser?>
    init(_ user: ConsoleUser?) { state = Mutex(user) }
    var value: ConsoleUser? {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = newValue } }
    }
}

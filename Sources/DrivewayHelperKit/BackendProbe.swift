import DrivewayCore
import Foundation

/// Asks the system whether macFUSE's kernel or FSKit backend may run. Run as root: `bputil -d` and the
/// KextPolicy database need it. Results are cached for 60 seconds. A tool that fails, can't run or exits
/// non-zero counts as "no" for its signal.
public actor BackendProbe: BackendProbing {
    public typealias Signals = (kextsAllowed: Bool, kextApproved: Bool, fskitEnabled: Bool)

    static let bputil = Command(executable: "/usr/bin/bputil", arguments: ["-d"])
    static let kextPolicy = Command(
        executable: "/usr/bin/sqlite3",
        arguments: ["-readonly", "-header", "/var/db/SystemPolicyConfiguration/KextPolicy", "select * from kext_policy;"])
    static let kmutil = Command(executable: "/usr/bin/kmutil", arguments: ["showloaded", "--list-only"])
    static let pluginkit = Command(
        executable: "/usr/bin/pluginkit", arguments: ["-m", "-v", "-p", "com.apple.fskit.fsmodule"])

    public static let cacheLifetime: Duration = .seconds(60)

    private let runner: any CommandRunning
    private let now: @Sendable () -> ContinuousClock.Instant
    private var cached: (value: Signals, at: ContinuousClock.Instant)?
    /// A probe in progress: concurrent callers share it instead of running the tools again.
    private var running: Task<Signals, Never>?

    public init(runner: any CommandRunning, now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }) {
        self.runner = runner
        self.now = now
    }

    public func probe() async -> Signals {
        if let cached, now() - cached.at < Self.cacheLifetime { return cached.value }
        if let running { return await running.value }
        let runner = self.runner
        let task = Task { await Self.measure(runner) }
        running = task
        let value = await task.value
        cached = (value, now())
        running = nil
        return value
    }

    static func measure(_ runner: any CommandRunning) async -> Signals {
        async let bputil = output(of: bputil, runner)
        async let policy = output(of: kextPolicy, runner)
        async let loaded = output(of: kmutil, runner)
        async let plugins = output(of: pluginkit, runner)
        let kextsAllowed = await bputil.map { MacFUSEProbe.kextsAllowed(bputilOutput: $0) } ?? false
        let inPolicy = await policy.map { MacFUSEProbe.kextApproved(kextPolicyRows: $0) } ?? false
        let isLoaded = await loaded.map { MacFUSEProbe.kextLoaded(kmutilOutput: $0) } ?? false
        let fskitEnabled = await plugins.map { MacFUSEProbe.isApproved(pluginkitOutput: $0) } ?? false
        return (kextsAllowed, inPolicy || isLoaded, fskitEnabled)
    }

    /// Standard output of a successful run; nil when the tool failed in any way.
    private static func output(of c: Command, _ runner: any CommandRunning) async -> String? {
        guard let r = try? await runner.run(c), r.exitCode == 0 else { return nil }
        return r.stdout
    }
}

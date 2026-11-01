import DrivewayCore
import DrivewayIPC
import Foundation
import os

/// Finds what's installed: the Homebrew tools, macFUSE and its backend, the helper and other NTFS/ext drivers.
struct ToolInventoryScanner: Sendable {
    static let helperTimeout: Duration = .seconds(2)
    static let toolTimeout: Duration = .seconds(5)
    static let macFUSEInfoPlist = "/Library/Filesystems/macfuse.fs/Contents/Info.plist"
    static let filesystems = "/Library/Filesystems"
    static let kmutil = (executable: "/usr/bin/kmutil", arguments: ["showloaded", "--list-only"])
    static let pluginkit = (executable: "/usr/bin/pluginkit", arguments: ["-m", "-v", "-p", "com.apple.fskit.fsmodule"])

    let client: HelperClient
    var paths = ToolPaths()

    func scan() async -> ToolInventory {
        let helperVersion = await helperVersion()
        let backend = await backend(helperReachable: helperVersion != nil)
        return ToolInventory(
            hasHomebrew: Self.isExecutable(paths.brew),
            macFUSEVersion: Self.macFUSEVersion(),
            backend: backend,
            hasNTFS3G: Self.isExecutable(paths.ntfs3g) && Self.isExecutable(paths.ntfsfix),
            hasExt4fuse: Self.isExecutable(paths.ext4fuse),
            hasE2fsprogs: Self.isExecutable(paths.e2fsck) && Self.isExecutable(paths.mkfsExt4),
            helperVersion: helperVersion,
            // The helper reports the same constant, so a mismatch means the helper is from another build.
            appVersion: helperProtocolVersion,
            conflictingDrivers: Self.conflictingDrivers())
    }

    /// The helper's version, or nil when it isn't installed, isn't running or doesn't answer in time.
    private func helperVersion() async -> String? {
        let client = client
        let reply = await withTimeout(Self.helperTimeout) { try await client.send(.helperVersion, authorized: false) }
        if case .version(let version)? = reply { return version }
        return nil
    }

    /// The helper's answer when it's reachable (only root can read the kext policy); otherwise what the user-level
    /// tools say, which never locks a feature on its own.
    private func backend(helperReachable: Bool) async -> BackendAvailability {
        if helperReachable {
            let client = client
            let reply = await withTimeout(Self.helperTimeout) { try await client.send(.backendStatus, authorized: false) }
            if case .backend(let availability)? = reply { return availability }
        }
        async let loaded = LineProcess.output(of: Self.kmutil.executable, Self.kmutil.arguments, timeout: Self.toolTimeout)
        async let plugins = LineProcess.output(
            of: Self.pluginkit.executable, Self.pluginkit.arguments, timeout: Self.toolTimeout)
        return BackendPolicy.availabilityWithoutHelper(kmutilOutput: await loaded, pluginkitOutput: await plugins)
    }

    private static func isExecutable(_ path: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: path)
    }

    private static func macFUSEVersion() -> SemanticVersion? {
        guard let info = NSDictionary(contentsOfFile: macFUSEInfoPlist),
              let version = info["CFBundleVersion"] as? String
        else { return nil }
        return SemanticVersion(version)
    }

    private static func conflictingDrivers() -> [String] {
        let bundles = (try? FileManager.default.contentsOfDirectory(atPath: filesystems)) ?? []
        return ConflictingDrivers.detect(filesystemBundles: bundles.sorted())
    }
}

/// The operation's result, or nil when it threw or didn't finish within `limit`. The operation isn't awaited past
/// the limit (an XPC call can't be canceled); its late result is dropped.
func withTimeout<T: Sendable>(
    _ limit: Duration, _ operation: @escaping @Sendable () async throws -> T
) async -> T? {
    await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
        let once = OSAllocatedUnfairLock<CheckedContinuation<T?, Never>?>(initialState: continuation)
        let resume: @Sendable (T?) -> Void = { value in once.withLock { $0.take() }?.resume(returning: value) }
        let timer = Task {
            do {
                try await Task.sleep(for: limit)
                resume(nil)
            } catch {}
        }
        Task {
            let value = try? await operation()
            timer.cancel()
            resume(value)
        }
    }
}

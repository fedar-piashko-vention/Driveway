import DrivewayCore
import DrivewayIPC
import Foundation
import Synchronization

public protocol AuthorizationVerifying: Sendable {
    func verify(_ externalForm: Data?, right: String) -> Bool
}

public protocol DiskInventoryProviding: Sendable {
    func disks() async -> [DiskDescription]
    /// The first bytes of the volume, read from its raw device.
    func header(of bsdName: String) async throws -> Data
    func bootWholeDisks() async -> Set<String>
    func usage(ofMountPoint: String) -> Int64?
    /// Polls the mount table for up to 5 seconds.
    func isMounted(at mountPoint: String) async -> Bool
}

public protocol BackendProbing: Sendable {
    func probe() async -> (kextsAllowed: Bool, kextApproved: Bool, fskitEnabled: Bool)
}

/// The root helper's logic. It refuses protected disks for every operation, whoever asks, and fails
/// closed: if the boot disk can't be determined, every disk counts as protected.
public actor HelperService {
    private let runner: any CommandRunning
    private let auth: any AuthorizationVerifying
    private let inventory: any DiskInventoryProviding
    private let store: any SettingsStoring
    private let paths: ToolPaths
    private let backendProbe: any BackendProbing
    private let osBuild: String
    private let consoleUser: @Sendable () -> ConsoleUser?
    private let features: @Sendable () -> [Feature: FeatureState]

    /// Volumes Driveway mounted, by BSD name.
    private var mounts: [String: Volume] = [:]
    /// Health notes for volumes that fell back to macOS's read-only mount.
    private var notes: [String: (health: VolumeHealth, lastError: String?)] = [:]
    /// Whole disks with an operation running; nothing else may touch them meanwhile.
    private var busy: Set<String> = []

    /// State that the nonisolated mount-approval callback reads.
    private struct Shared {
        var boot: Set<String>?
        var disks: [DiskDescription] = []
        var backend: BackendAvailability?
        var detected: [String: FilesystemKind] = [:]
        var macOSMountAllowed: Set<String> = []
        /// Disks Driveway mounted or is mounting.
        var claimed: Set<String> = []
        /// Disks whose macOS mount the approval callback refused.
        var blocked: Set<String> = []
    }
    private let shared = Mutex(Shared())

    public init(
        runner: any CommandRunning, auth: any AuthorizationVerifying, inventory: any DiskInventoryProviding,
        settings: any SettingsStoring, paths: ToolPaths, backendProbe: any BackendProbing, osBuild: String,
        consoleUser: @escaping @Sendable () -> ConsoleUser?,
        features: @escaping @Sendable () -> [Feature: FeatureState]
    ) {
        self.runner = runner
        self.auth = auth
        self.inventory = inventory
        self.store = settings
        self.paths = paths
        self.backendProbe = backendProbe
        self.osBuild = osBuild
        self.consoleUser = consoleUser
        self.features = features
    }

    // MARK: - Requests

    public func handle(_ request: HelperRequest, authorization: Data?) async -> HelperResponse {
        switch request {
        case .listVolumes: return .volumes(await listVolumes())
        case .getSettings: return .settings(store.load())
        case .setSettings(var s):
            s.fskitFailedOnOSBuild = store.load().fskitFailedOnOSBuild  // the helper's record, not the app's
            do {
                try store.save(s)
                return .ok
            } catch {
                return .error(.commandFailed("Couldn't save settings: \(error.localizedDescription)"))
            }
        case .helperVersion: return .version(helperProtocolVersion)
        case .backendStatus: return .backend(await backendAvailability())
        case .format(let r): return await format(r, authorization: authorization)
        case .mount(let bsd), .unmount(let bsd), .eject(let bsd), .fixAndMount(let bsd), .check(let bsd),
            .repair(let bsd, _), .backup(let bsd, _):
            let d: DiskDescription
            let ctx: Context
            switch await resolve(bsd, request: request, authorization: authorization) {
            case .failure(let e): return .error(e)
            case .success(let resolved): (d, ctx) = resolved
            }
            busy.insert(d.wholeDisk)
            defer { busy.remove(d.wholeDisk) }
            switch request {
            case .mount: return await mount(d, ctx)
            case .unmount: return await unmount(d)
            case .eject: return await eject(d)
            case .fixAndMount: return await fixAndMount(d, ctx)
            case .check: return await checkOrRepair(d, ctx, mode: .check)
            case .repair(_, let force): return await checkOrRepair(d, ctx, mode: force ? .repairForce : .repair)
            case .backup(_, let imagePath): return await backup(d, ctx, imagePath: imagePath)
            default: return .error(.unknownVolume)
            }
        }
    }

    private struct Context {
        var disks: [DiskDescription]
        var policy: ProtectionPolicy
        var settings: DrivewaySettings
    }

    /// Reads the boot disks, the disk list and the settings. Nil (fail closed) when no boot disk is known.
    private func context() async -> Context? {
        let boot = await inventory.bootWholeDisks()
        let disks = await inventory.disks()
        let settings = store.load()
        shared.withLock {
            $0.boot = boot
            $0.disks = disks
        }
        guard !boot.isEmpty else { return nil }
        let policy = ProtectionPolicy(bootWholeDisks: boot, allowDiskImages: settings.allowDiskImagesForTesting)
        return Context(disks: disks, policy: policy, settings: settings)
    }

    /// Name check, then lookup, then protection, then authorization, then the busy check.
    private func resolve(
        _ bsd: String, request: HelperRequest, authorization: Data?
    ) async -> Result<(DiskDescription, Context), HelperError> {
        guard Self.isValidBSDName(bsd) else { return .failure(.unknownVolume) }
        guard let ctx = await context() else { return .failure(.protectedDisk) }
        guard let d = ctx.disks.first(where: { $0.bsdName == bsd }) else { return .failure(.unknownVolume) }
        if ctx.policy.isProtected(d, allDisks: ctx.disks) { return .failure(.protectedDisk) }
        if request.requiresAuthorization, !auth.verify(authorization, right: AuthorizationRights.modifyDisk) {
            return .failure(.notAuthorized)
        }
        if busy.contains(d.wholeDisk) { return .failure(.commandFailed(Self.busyMessage)) }
        return .success((d, ctx))
    }

    private func listVolumes() async -> [Volume] {
        guard let ctx = await context() else { return [] }
        var volumes: [Volume] = []
        for d in ctx.disks where Self.isValidBSDName(d.bsdName) && !Self.isEFI(d) {
            guard !ctx.policy.isProtected(d, allDisks: ctx.disks) else { continue }
            if var v = mounts[d.bsdName] {
                v.usedBytes = v.mountPoint.flatMap { inventory.usage(ofMountPoint: $0) }
                volumes.append(v)
            } else if let fs = await filesystem(of: d) {
                volumes.append(describe(d, fs))
            }
        }
        return volumes
    }

    private func mount(_ d: DiskDescription, _ ctx: Context, knownFilesystem: FilesystemKind? = nil) async -> HelperResponse {
        if let existing = mounts[d.bsdName] { return .volume(existing) }
        var fs = FilesystemKind.other
        if let knownFilesystem { fs = knownFilesystem } else if let detected = await filesystem(of: d) { fs = detected }
        if case .takeOver(let backend, let user) = await plan(d, fs, ctx.settings, explicit: true) {
            switch await takeOver(d, fs, backend: backend, user: user, ctx: ctx) {
            case .mounted(let v), .readOnly(let v, _): return .volume(v)
            case .failed(_, _, let e): return .error(e)
            }
        }
        if d.volumePath != nil { return .volume(describe(d, fs)) }
        switch await handBackToMacOS(d.bsdName) {
        case .failure(let e): return .error(e)
        case .success: return .volume(describe(await refreshed(d), fs))
        }
    }

    private func unmount(_ d: DiskDescription) async -> HelperResponse {
        guard d.volumePath != nil || mounts[d.bsdName] != nil else { return .ok }
        if case .failure(let e) = await runOK(ToolCommands.unmount(device: "/dev/\(d.bsdName)", paths: paths)) {
            return .error(e)
        }
        forget(d.bsdName)
        return .ok
    }

    private func eject(_ d: DiskDescription) async -> HelperResponse {
        if case .failure(let e) = await runOK(ToolCommands.diskutil("eject", "/dev/\(d.wholeDisk)", paths: paths)) {
            return .error(e)
        }
        for (bsd, v) in mounts where v.wholeDisk == d.wholeDisk { forget(bsd) }
        return .ok
    }

    private func fixAndMount(_ d: DiskDescription, _ ctx: Context) async -> HelperResponse {
        guard await filesystem(of: d) == .ntfs else { return .error(.commandFailed("Fix & mount is only for NTFS drives.")) }
        let wasMounted = d.volumePath != nil || mounts[d.bsdName] != nil
        if wasMounted {
            if case .failure(let e) = await runOK(ToolCommands.unmount(device: "/dev/\(d.bsdName)", paths: paths)) {
                return .error(e)
            }
            forget(d.bsdName)
        }
        if case .failure(let e) = await runOK(ToolCommands.ntfsfix(device: "/dev/\(d.bsdName)", mode: .repair, paths: paths)) {
            if wasMounted { _ = await handBackToMacOS(d.bsdName) }
            return .error(e)
        }
        var unmounted = d
        unmounted.volumePath = nil
        return await mount(unmounted, ctx, knownFilesystem: .ntfs)
    }

    private func checkOrRepair(_ d: DiskDescription, _ ctx: Context, mode: CheckMode) async -> HelperResponse {
        let fs = await filesystem(of: d) ?? .other
        let device = "/dev/\(d.bsdName)"
        let result: Result<CommandResult, HelperError>
        switch fs {
        case .exfat, .fat32, .fat16:
            result = await run(ToolCommands.diskutil(mode == .check ? "verifyVolume" : "repairVolume", device, paths: paths))
        case .ntfs:
            result = await whileUnmounted(d, ctx, ToolCommands.ntfsfix(device: device, mode: mode, paths: paths))
        case .ext2, .ext3, .ext4:
            result = await whileUnmounted(d, ctx, ToolCommands.e2fsck(device: device, mode: mode, paths: paths))
        case .other:
            return .error(.commandFailed("Check and repair aren't available for this drive's format."))
        }
        switch result {
        case .failure(let e): return .error(e)
        case .success(let r): return .report(Self.report(fs, mode: fs == .ntfs && mode == .repairForce ? .repair : mode, r))
        }
    }

    private func backup(_ d: DiskDescription, _ ctx: Context, imagePath: String) async -> HelperResponse {
        guard await filesystem(of: d) == .ntfs else { return .error(.commandFailed("Back up is only for NTFS drives.")) }
        guard Self.isSafeImagePath(imagePath) else { return .error(.commandFailed(Self.badImagePathMessage)) }
        let command = ToolCommands.ntfsclone(device: "/dev/\(d.bsdName)", imagePath: imagePath, paths: paths)
        switch await whileUnmounted(d, ctx, command) {
        case .failure(let e): return .error(e)
        case .success(let r): return r.exitCode == 0 ? .ok : .error(.commandFailed(Self.message(r, command)))
        }
    }

    /// Unmounts `d` if it is mounted, runs `command`, then mounts it again.
    private func whileUnmounted(
        _ d: DiskDescription, _ ctx: Context, _ command: Command
    ) async -> Result<CommandResult, HelperError> {
        let wasMounted = d.volumePath != nil || mounts[d.bsdName] != nil
        if wasMounted {
            if case .failure(let e) = await runOK(ToolCommands.unmount(device: "/dev/\(d.bsdName)", paths: paths)) {
                return .failure(e)
            }
            forget(d.bsdName)
        }
        let result = await run(command)
        if wasMounted {
            var unmounted = d
            unmounted.volumePath = nil
            _ = await mount(unmounted, ctx)
        }
        return result
    }

    // MARK: - Format

    private func format(_ r: FormatRequest, authorization: Data?) async -> HelperResponse {
        let target: String
        switch r.target {
        case .wholeDisk(let name), .partition(let name): target = name
        }
        guard Self.isValidBSDName(target) else { return .error(.unknownVolume) }
        guard let ctx = await context() else { return .error(.protectedDisk) }
        guard let d = ctx.disks.first(where: { $0.bsdName == target }) else { return .error(.unknownVolume) }
        do throws(FormatValidationError) {
            try validate(r, currentDriveName: Self.confirmationName(for: r, target: d, in: ctx.disks))
        } catch {
            return .error(.validation(error))
        }
        if ctx.policy.isProtected(d, allDisks: ctx.disks) { return .error(.protectedDisk) }
        guard auth.verify(authorization, right: AuthorizationRights.modifyDisk) else { return .error(.notAuthorized) }
        guard !busy.contains(d.wholeDisk) else { return .error(.commandFailed(Self.busyMessage)) }
        busy.insert(d.wholeDisk)
        defer { busy.remove(d.wholeDisk) }

        for (bsd, v) in mounts where bsd == target || (d.isWholeMedia && v.wholeDisk == d.wholeDisk) { forget(bsd) }
        for c in FormatPlanner.eraseCommands(r, paths: paths) {
            if case .failure(let e) = await runOK(c) { return .error(e) }
        }
        guard r.filesystem == .ntfs || r.filesystem == .ext4 else { return .ok }

        // The erase can renumber partitions, so the data partition comes from a fresh list.
        let fresh = await inventory.disks()
        let dataName: String?
        switch r.target {
        case .wholeDisk(let whole): dataName = FormatPlanner.dataPartition(of: whole, in: fresh)
        case .partition(let partition): dataName = partition
        }
        guard let dataName, let data = fresh.first(where: { $0.bsdName == dataName }), data.wholeDisk == d.wholeDisk
        else { return .error(.commandFailed("The erased partition didn't come back. Nothing was formatted.")) }
        guard !Self.isEFI(data) else {
            return .error(.commandFailed("The target is now an EFI system partition. Nothing was formatted."))
        }
        if ctx.policy.isProtected(data, allDisks: fresh) { return .error(.protectedDisk) }
        let finish = FormatPlanner.finishCommands(r, dataPartition: dataName, paths: paths)
        guard !finish.isEmpty else { return .error(.commandFailed("Couldn't plan the format. Nothing was formatted.")) }
        for c in finish {
            if case .failure(let e) = await runOK(c) { return .error(e) }
        }

        var formatted = data
        formatted.volumePath = nil
        formatted.volumeName = r.label
        var freshCtx = ctx
        freshCtx.disks = fresh
        let mounted = await mount(formatted, freshCtx, knownFilesystem: r.filesystem)
        if case .volume(let v?) = mounted { return .volume(v) }
        return .ok
    }

    // MARK: - Disk events

    public func diskAppeared(_ disk: DiskDescription) async -> VolumeEvent? {
        guard Self.isValidBSDName(disk.bsdName), let ctx = await context() else { return nil }
        let d = ctx.disks.first { $0.bsdName == disk.bsdName } ?? disk
        guard !ctx.policy.isProtected(d, allDisks: ctx.disks) else { return nil }
        if let existing = mounts[d.bsdName] { return .mounted(existing) }
        guard !busy.contains(d.wholeDisk) else { return nil }
        busy.insert(d.wholeDisk)
        defer { busy.remove(d.wholeDisk) }

        guard let fs = await filesystem(of: d) else { return await leaveToMacOS(d) }
        switch await plan(d, fs, ctx.settings, explicit: false) {
        case .backOff(let driver):
            _ = await leaveToMacOS(d)
            return .backedOff(describe(d, fs), driver: driver)
        case .leave:
            return await leaveToMacOS(d)
        case .takeOver(let backend, let user):
            switch await takeOver(d, fs, backend: backend, user: user, ctx: ctx) {
            case .mounted(let v): return .mounted(v)
            case .readOnly(let v, let reason): return .mountedReadOnly(v, reason: reason)
            case .failed(let v, let message, _): return .mountFailed(v, message: message)
            }
        }
    }

    public func diskDisappeared(_ bsdName: String) async -> VolumeEvent {
        forget(bsdName)
        notes[bsdName] = nil
        shared.withLock {
            $0.macOSMountAllowed.remove(bsdName)
            $0.detected[bsdName] = nil
        }
        return .removed(bsdName: bsdName)
    }

    /// Called from DiskArbitration's mount-approval callback: false only when Driveway will mount the disk
    /// itself. Anything unknown (boot disks, backend) approves, so macOS's read-only mount is the fallback.
    public nonisolated func shouldApproveMacOSMount(_ disk: DiskDescription) -> Bool {
        let bsd = disk.bsdName
        guard Self.isValidBSDName(bsd) else { return true }
        let s = shared.withLock { $0 }
        if s.macOSMountAllowed.contains(bsd) { return true }
        if s.claimed.contains(bsd) { return false }
        guard let boot = s.boot, !boot.isEmpty, case .ready = s.backend else { return true }
        let settings = store.load()
        let policy = ProtectionPolicy(bootWholeDisks: boot, allowDiskImages: settings.allowDiskImagesForTesting)
        if policy.isProtected(disk, allDisks: s.disks) { return true }
        let fs = s.detected[bsd]
            ?? FilesystemProbe.kind(forDAVolumeKind: disk.volumeKind, volumeType: disk.volumeType) ?? .other
        let action = autoMountAction(
            filesystem: fs, mountedBy: Self.owner(of: disk) ?? MountOwner.none, settingsKey: disk.settingsKey, settings: settings,
            features: features(), consoleUser: Self.loggedIn(consoleUser()))
        guard action == .mountNTFSReadWrite || action == .mountExtReadOnly else { return true }
        shared.withLock { _ = $0.blocked.insert(bsd) }
        return false
    }

    // MARK: - Mounting

    private enum Plan {
        case takeOver(MountBackend, ConsoleUser)
        case leave
        case backOff(String)
    }

    /// `explicit` is a user's Mount click: the auto-mount switch doesn't apply, the per-drive read-only one does.
    private func plan(_ d: DiskDescription, _ fs: FilesystemKind, _ settings: DrivewaySettings, explicit: Bool) async -> Plan {
        var settings = settings
        if explicit { settings.autoMountNTFS = true }
        let user = Self.loggedIn(consoleUser())
        let action = autoMountAction(
            filesystem: fs, mountedBy: Self.owner(of: d) ?? MountOwner.none, settingsKey: d.settingsKey, settings: settings,
            features: features(), consoleUser: user)
        switch action {
        case .backOff(let driver): return .backOff(driver)
        case .leaveToMacOS: return .leave
        case .mountNTFSReadWrite, .mountExtReadOnly:
            guard let user, case .ready(let backend) = await backendAvailability() else { return .leave }
            return .takeOver(backend, user)
        }
    }

    private enum MountResult {
        case mounted(Volume)
        case readOnly(Volume, ReadOnlyReason)
        case failed(Volume, String, HelperError)
    }

    private func takeOver(
        _ d: DiskDescription, _ fs: FilesystemKind, backend: MountBackend, user: ConsoleUser, ctx: Context
    ) async -> MountResult {
        let bsd = d.bsdName
        let device = "/dev/\(bsd)"
        shared.withLock {
            $0.claimed.insert(bsd)
            $0.macOSMountAllowed.remove(bsd)
        }
        var v = describe(d, fs)
        if d.volumePath != nil {
            if case .failure(let e) = await runOK(ToolCommands.unmount(device: device, paths: paths)) {
                shared.withLock { _ = $0.claimed.remove(bsd) }
                return .failed(v, Self.text(e), e)
            }
            v.mountPoint = nil
            v.access = .notMounted
        }
        let label = Self.displayLabel(d)
        let others = ctx.disks.filter { $0.bsdName != bsd }.compactMap(\.volumePath)
            + mounts.values.filter { $0.bsdName != bsd }.compactMap(\.mountPoint)
        let mountPoint = MountNaming.mountPoint(for: label, existing: Set(others))
        let command = fs == .ntfs
            ? ToolCommands.ntfs3gMount(
                device: device, mountPoint: mountPoint, volumeName: label, readOnly: false, uid: user.uid,
                gid: user.gid, backend: backend, paths: paths)
            : ToolCommands.ext4fuseMount(
                device: device, mountPoint: mountPoint, volumeName: label, backend: backend, paths: paths)

        let result: CommandResult
        switch await run(command) {
        case .failure(let e):
            if fs == .ntfs { _ = await handBackToMacOS(bsd) } else { release(bsd) }
            return .failed(v, Self.text(e), e)
        case .success(let r): result = r
        }

        if result.exitCode == 0 {
            if await inventory.isMounted(at: mountPoint) {
                v.mountPoint = mountPoint
                v.access = fs == .ntfs ? .readWrite : .readOnly
                v.health = fs == .ntfs ? .clean : .unknown
                v.mountedBy = .driveway
                v.backend = backend
                v.lastError = nil
                v.usedBytes = inventory.usage(ofMountPoint: mountPoint)
                mounts[bsd] = v
                notes[bsd] = nil
                return .mounted(v)
            }
            if backend == .fskit {
                var s = store.load()
                s.fskitFailedOnOSBuild = osBuild
                try? store.save(s)
                shared.withLock { $0.backend = .unavailable }
            }
            let message = "The drive didn't appear in Finder after mounting."
            _ = await handBackToMacOS(bsd)
            v.lastError = message
            return .failed(v, message, .commandFailed(message))
        }

        guard fs == .ntfs else {
            release(bsd)
            let message = Self.message(result, command)
            v.lastError = message
            return .failed(v, message, .commandFailed(message))
        }
        let outcome = NTFSMountOutcome.classify(exitCode: result.exitCode, stderr: result.stderr)
        let fallback = readOnlyFallback(after: outcome)
        let reason: ReadOnlyReason =
            switch outcome {
            case .dirty: .dirty
            case .hibernated: .hibernated
            default: .error(fallback.reason ?? Self.message(result, command))
            }
        notes[bsd] = (fallback.health, fallback.reason)
        v.health = fallback.health
        v.lastError = fallback.reason
        if case .failure(let e) = await handBackToMacOS(bsd) {
            return .failed(v, fallback.reason ?? Self.text(e), e)
        }
        var ro = describe(await refreshed(d), fs)
        ro.mountedBy = .macOS
        ro.access = .readOnly
        return .readOnly(ro, reason)
    }

    /// Lets macOS mount the disk (read-only for NTFS) and asks it to.
    private func handBackToMacOS(_ bsd: String) async -> Result<CommandResult, HelperError> {
        release(bsd)
        return await runOK(ToolCommands.diskutil("mount", "/dev/\(bsd)", paths: paths))
    }

    /// Leaves the disk to macOS. If the approval callback refused macOS's mount earlier, asks macOS to mount it now.
    private func leaveToMacOS(_ d: DiskDescription) async -> VolumeEvent? {
        let wasBlocked = shared.withLock { $0.blocked.contains(d.bsdName) }
        release(d.bsdName)
        if wasBlocked, d.volumePath == nil { _ = await runOK(ToolCommands.diskutil("mount", "/dev/\(d.bsdName)", paths: paths)) }
        return nil
    }

    private func release(_ bsd: String) {
        shared.withLock {
            $0.claimed.remove(bsd)
            $0.blocked.remove(bsd)
            $0.macOSMountAllowed.insert(bsd)
        }
    }

    private func forget(_ bsd: String) {
        mounts[bsd] = nil
        shared.withLock {
            $0.claimed.remove(bsd)
            $0.blocked.remove(bsd)
        }
    }

    private func backendAvailability() async -> BackendAvailability {
        let p = await backendProbe.probe()
        let availability = BackendPolicy.availability(
            kextsAllowed: p.kextsAllowed, kextApproved: p.kextApproved, fskitEnabled: p.fskitEnabled,
            fskitFailedOnThisOS: store.load().fskitFailedOnOSBuild == osBuild)
        shared.withLock { $0.backend = availability }
        return availability
    }

    // MARK: - Helpers

    /// The volume's header first; DiskArbitration's kind only when the header says nothing or can't be read
    /// (DiskArbitration has reported a fresh NTFS partition as exFAT).
    private func filesystem(of d: DiskDescription) async -> FilesystemKind? {
        let fromHeader = (try? await inventory.header(of: d.bsdName)).flatMap(FilesystemProbe.detect(header:))
        let kind = fromHeader ?? FilesystemProbe.kind(forDAVolumeKind: d.volumeKind, volumeType: d.volumeType)
        if let kind { shared.withLock { $0.detected[d.bsdName] = kind } }
        return kind
    }

    private func refreshed(_ d: DiskDescription) async -> DiskDescription {
        await inventory.disks().first { $0.bsdName == d.bsdName } ?? d
    }

    /// The disk as it is now, mounted by macOS, another driver or nothing.
    private func describe(_ d: DiskDescription, _ fs: FilesystemKind) -> Volume {
        let owner: MountOwner = Self.owner(of: d) ?? (d.volumePath == nil ? MountOwner.none : MountOwner.macOS)
        let access: AccessMode =
            d.volumePath == nil ? .notMounted : (owner == .macOS && fs.isDrivewayManaged ? .readOnly : .readWrite)
        let note = notes[d.bsdName]
        return Volume(
            bsdName: d.bsdName, wholeDisk: d.wholeDisk, label: Self.displayLabel(d), filesystem: fs,
            capacityBytes: d.sizeBytes, usedBytes: d.volumePath.flatMap { inventory.usage(ofMountPoint: $0) },
            mountPoint: d.volumePath, access: access, health: note?.health ?? .unknown, mountedBy: owner,
            deviceModel: d.deviceModel, settingsKey: d.settingsKey, lastError: note?.lastError)
    }

    private func run(_ c: Command) async -> Result<CommandResult, HelperError> {
        do {
            return .success(try await runner.run(c))
        } catch CommandRunnerError.toolMissing(let path) {
            return .failure(.toolMissing(path))
        } catch {
            return .failure(.commandFailed(String(describing: error)))
        }
    }

    /// Like `run`, but a non-zero exit is a failure carrying the tool's message.
    private func runOK(_ c: Command) async -> Result<CommandResult, HelperError> {
        switch await run(c) {
        case .success(let r) where r.exitCode == 0: .success(r)
        case .success(let r): .failure(.commandFailed(Self.message(r, c)))
        case .failure(let e): .failure(e)
        }
    }

    static let busyMessage = "Another operation is running on this drive."
    static let badImagePathMessage = "Choose a file location for the backup image."

    /// `^disk[0-9]+(s[0-9]+)?$`, ASCII digits only.
    static func isValidBSDName(_ s: String) -> Bool {
        let scalars = Array(s.unicodeScalars)
        guard scalars.count > 4, String(String.UnicodeScalarView(scalars[0..<4])) == "disk" else { return false }
        func isDigit(_ c: Unicode.Scalar) -> Bool { c.value >= 0x30 && c.value <= 0x39 }
        var i = 4
        let wholeStart = i
        while i < scalars.count, isDigit(scalars[i]) { i += 1 }
        guard i > wholeStart else { return false }
        if i == scalars.count { return true }
        guard scalars[i] == "s" else { return false }
        i += 1
        let sliceStart = i
        while i < scalars.count, isDigit(scalars[i]) { i += 1 }
        return i > sliceStart && i == scalars.count
    }

    static func isEFI(_ d: DiskDescription) -> Bool {
        guard let c = d.contentType?.uppercased() else { return false }
        return c == "EFI" || c == "C12A7328-F81F-11D2-BA4B-00A0C93EC93B"
    }

    static func displayLabel(_ d: DiskDescription) -> String {
        guard let name = d.volumeName, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Untitled"
        }
        return name
    }

    static func owner(of d: DiskDescription) -> MountOwner? {
        ConflictingDrivers.driverName(forDAVolumeKind: d.volumeKind).map { .otherDriver($0) }
    }

    /// uid 0 is the login window: nobody is logged in.
    static func loggedIn(_ user: ConsoleUser?) -> ConsoleUser? {
        user.flatMap { $0.uid == 0 ? nil : $0 }
    }

    /// The name the user must type: the partition's label, or for a whole disk the label of any non-EFI volume on it.
    static func confirmationName(for r: FormatRequest, target d: DiskDescription, in disks: [DiskDescription]) -> String {
        let candidates: [DiskDescription]
        switch r.target {
        case .partition: candidates = [d]
        case .wholeDisk(let whole):
            candidates = disks.filter { $0.wholeDisk == whole && !isEFI($0) && (!$0.isWholeMedia || $0.volumeKind != nil) }
        }
        let names = candidates.map(displayLabel)
        let typed = r.confirmation.trimmingCharacters(in: .whitespacesAndNewlines)
        return names.first { $0.trimmingCharacters(in: .whitespacesAndNewlines) == typed } ?? names.first ?? ""
    }

    /// An absolute path to a file outside /dev, with no ".." components.
    static func isSafeImagePath(_ path: String) -> Bool {
        guard path.hasPrefix("/"), !path.hasSuffix("/"), !path.contains("\0"), !path.hasPrefix("/dev/") else { return false }
        return !path.split(separator: "/").contains("..")
    }

    static func message(_ r: CommandResult, _ c: Command) -> String {
        for text in [r.stderr, r.stdout] {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return "\(URL(fileURLWithPath: c.executable).lastPathComponent) exited with code \(r.exitCode)"
    }

    static func text(_ e: HelperError) -> String {
        switch e {
        case .commandFailed(let m): m
        case .toolMissing(let path): "\(path) is not installed."
        default: String(describing: e)
        }
    }

    static func report(_ fs: FilesystemKind, mode: CheckMode, _ r: CommandResult) -> CheckReport {
        let raw = [r.stdout, r.stderr].filter { !$0.isEmpty }.joined(separator: "\n")
        let succeeded: Bool
        let summary: String
        switch fs {
        case .ntfs:
            succeeded = NTFSFixReport.parse(raw).succeeded
            summary = succeeded
                ? (mode == .check ? "No problems found." : "Repaired.")
                : (mode == .check ? "ntfsfix found problems." : "ntfsfix couldn't repair this drive.")
        case .ext2, .ext3, .ext4:
            switch E2fsckOutcome.from(exitCode: r.exitCode) {
            case .clean: (succeeded, summary) = (true, "No problems found.")
            case .corrected: (succeeded, summary) = (true, "Problems were found and fixed.")
            case .correctedNeedsReboot: (succeeded, summary) = (true, "Problems were found and fixed.")
            case .uncorrected: (succeeded, summary) = (false, "Problems were found and not fixed.")
            case .operationalError: (succeeded, summary) = (false, "e2fsck couldn't check this drive.")
            case .cancelled: (succeeded, summary) = (false, "The check was cancelled.")
            }
        default:
            succeeded = r.exitCode == 0
            summary = succeeded
                ? (mode == .check ? "No problems found." : "Repaired.")
                : (mode == .check ? "macOS found problems." : "macOS couldn't repair this drive.")
        }
        return CheckReport(filesystem: fs, mode: mode, succeeded: succeeded, summary: summary, rawOutput: raw)
    }
}

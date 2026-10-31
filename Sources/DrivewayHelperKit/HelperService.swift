import DrivewayCore
import DrivewayIPC
import Foundation
import Synchronization

/// The root helper's logic. It refuses protected disks for every operation, whoever asks, and fails
/// closed: if the boot disk can't be determined, every disk counts as protected.
///
/// Work on one whole disk is serialised: every request and disk event that touches a disk waits its
/// turn in a first-in, first-out queue for that whole disk instead of being refused or dropped.
public actor HelperService {
    /// Runs commands with a time limit: mounts, unmounts and diskutil queries.
    let runner: any CommandRunning
    /// Runs commands that may take hours and must never be stopped half-way: check, repair, backup, format.
    let unboundedRunner: any CommandRunning
    let auth: any AuthorizationVerifying
    let inventory: any DiskInventoryProviding
    let store: any SettingsStoring
    let paths: ToolPaths
    let backendProbe: any BackendProbing
    let osBuild: String
    let consoleUser: @Sendable () -> ConsoleUser?
    let features: @Sendable () -> [Feature: FeatureState]
    /// Told the backend's availability whenever the app asks for it (Setup does, after each step), so the
    /// feature states can be refreshed at once.
    let backendChecked: @Sendable (BackendAvailability) -> Void
    /// Gets the `.progress` events of a running check, repair or backup, to broadcast to connected clients.
    let progress: @Sendable (VolumeEvent) -> Void
    let log: @Sendable (String) -> Void

    /// Volumes Driveway mounted, by BSD name.
    var mounts: [String: Volume] = [:]
    /// Health notes for volumes that fell back to macOS's read-only mount.
    var notes: [String: (health: VolumeHealth, lastError: String?)] = [:]
    /// Whole disk -> tasks waiting for it. A key that is present means the disk is held.
    private var diskQueues: [String: [CheckedContinuation<Void, Never>]] = [:]
    /// Disks that disappeared while their whole disk was held. Settled when the operation finishes.
    private var pendingRemovals: Set<String> = []
    /// FSKit failed to mount on this OS build. Kept here too, so a failed settings save can't make the
    /// next probe try FSKit again.
    var fskitFailedThisBuild = false

    /// State that the nonisolated mount-approval callback reads.
    struct Shared {
        var boot: Set<String>?
        var disks: [DiskDescription] = []
        var backend: BackendAvailability?
        var detected: [String: FilesystemKind] = [:]
        var macOSMountAllowed: Set<String> = []
        /// Disks Driveway mounted or is mounting.
        var claimed: Set<String> = []
        /// Disks whose macOS mount the approval callback refused.
        var blocked: Set<String> = []
        /// Whole disks being formatted: macOS may mount anything on them meanwhile.
        var formatting: Set<String> = []
        /// The settings as last loaded or saved. The helper is the only writer of the settings file, so
        /// the file is read once, at init; the mount-approval callback never touches it.
        var settings = DrivewaySettings()
    }
    let shared = Mutex(Shared())

    public init(
        runner: any CommandRunning, unboundedRunner: (any CommandRunning)? = nil, auth: any AuthorizationVerifying, inventory: any DiskInventoryProviding,
        settings: any SettingsStoring, paths: ToolPaths, backendProbe: any BackendProbing, osBuild: String,
        consoleUser: @escaping @Sendable () -> ConsoleUser?,
        features: @escaping @Sendable () -> [Feature: FeatureState],
        backendChecked: @escaping @Sendable (BackendAvailability) -> Void = { _ in },
        progress: @escaping @Sendable (VolumeEvent) -> Void = { _ in },
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.runner = runner
        self.unboundedRunner = unboundedRunner ?? runner
        self.auth = auth
        self.inventory = inventory
        self.store = settings
        self.paths = paths
        self.backendProbe = backendProbe
        self.osBuild = osBuild
        self.consoleUser = consoleUser
        self.features = features
        self.backendChecked = backendChecked
        self.progress = progress
        self.log = log
        let loaded = settings.load()
        shared.withLock { $0.settings = loaded }
    }

    /// The settings held in memory.
    nonisolated var currentSettings: DrivewaySettings { shared.withLock { $0.settings } }

    /// Writes the settings file, then (only if that worked) the copy in memory.
    func saveSettings(_ s: DrivewaySettings) throws {
        try store.save(s)
        shared.withLock { $0.settings = s }
    }

    // MARK: - Requests

    public func handle(_ request: HelperRequest, authorization: Data?) async -> HelperResponse {
        switch request {
        case .listVolumes: return .volumes(await listVolumes())
        case .getSettings: return .settings(currentSettings)
        case .setSettings(let s): return setSettings(s, authorization: authorization)
        case .helperVersion: return .version(helperProtocolVersion)
        case .backendStatus:
            let availability = await backendAvailability()
            backendChecked(availability)
            return .backend(availability)
        case .format(let r): return await format(r, authorization: authorization)
        case .mount(let ref), .unmount(let ref), .eject(let ref), .fixAndMount(let ref), .check(let ref),
            .repair(let ref, _), .backup(let ref, _):
            guard Self.isValidBSDName(ref.bsdName) else { return .error(.unknownVolume) }
            // Checked before waiting for the disk: the administrator's credential is only good for a short
            // while (the right's timeout), and the wait can be as long as another drive operation.
            let authorized = !request.requiresAuthorization || auth.verify(authorization, right: AuthorizationRights.modifyDisk)
            let key = Self.lockKey(ref.bsdName)
            await lockDisk(key)
            let response = await diskRequest(request, ref, authorized: authorized)
            await releaseDisk(key)
            return response
        }
    }

    /// A request for one disk. The caller holds the disk's queue.
    private func diskRequest(_ request: HelperRequest, _ ref: DiskRef, authorized: Bool) async -> HelperResponse {
        let d: DiskDescription
        let ctx: Context
        switch await resolve(ref, request: request, authorized: authorized) {
        case .failure(let e): return .error(e)
        case .success(let resolved): (d, ctx) = resolved
        }
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

    struct Context {
        var disks: [DiskDescription]
        var policy: ProtectionPolicy
        var settings: DrivewaySettings
    }

    /// Reads the boot disks, the disk list and the settings. Nil (fail closed) when no boot disk is known.
    func context() async -> Context? {
        let boot = await inventory.bootWholeDisks()
        let disks = await inventory.disks()
        let settings = currentSettings
        shared.withLock {
            $0.boot = boot
            $0.disks = disks
        }
        guard !boot.isEmpty else { return nil }
        let policy = ProtectionPolicy(bootWholeDisks: boot, allowDiskImages: settings.allowDiskImagesForTesting)
        return Context(disks: disks, policy: policy, settings: settings)
    }

    /// Name check, then lookup, then identity (the drive must still be the one the app showed), then
    /// protection (the EFI system partition included), then authorization. The caller holds the disk's queue.
    private func resolve(
        _ ref: DiskRef, request: HelperRequest, authorized: Bool
    ) async -> Result<(DiskDescription, Context), HelperError> {
        let bsd = ref.bsdName
        guard Self.isValidBSDName(bsd) else { return .failure(.unknownVolume) }
        guard let ctx = await context() else { return .failure(.protectedDisk) }
        guard let d = ctx.disks.first(where: { $0.bsdName == bsd }) else { return .failure(.unknownVolume) }
        guard identityMatches(d, key: ref.key) else { return .failure(.unknownVolume) }
        if Self.isEFI(d) || ctx.policy.isProtected(d, allDisks: ctx.disks) { return .failure(.protectedDisk) }
        if !authorized { return .failure(.notAuthorized) }
        return .success((d, ctx))
    }

    /// True when `key` is the `settingsKey` Driveway shows for `d`: the one recorded when Driveway mounted it,
    /// or the one its description gives now.
    func identityMatches(_ d: DiskDescription, key: String) -> Bool {
        key == d.settingsKey || key == mounts[d.bsdName]?.settingsKey
    }

    /// Waits until no other operation holds `key`, first come first served, then holds it.
    func lockDisk(_ key: String) async {
        if diskQueues[key] == nil {
            diskQueues[key] = []
            return
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            diskQueues[key, default: []].append(c)
        }
    }

    /// Settles removals that arrived during the operation, still holding the disk, then hands it on.
    /// A disk that disappeared but is back in the inventory (an erase renumbering it, say) keeps its state.
    func releaseDisk(_ key: String) async {
        while case let pending = pendingRemovals.filter({ Self.lockKey($0) == key }), !pending.isEmpty {
            pendingRemovals.subtract(pending)
            let present = Set(await inventory.disks().map(\.bsdName))
            for bsd in pending where !present.contains(bsd) { clearRemoved(bsd) }
        }
        unlockDisk(key)
    }

    /// Hands `key` straight to the next waiter, or frees it.
    private func unlockDisk(_ key: String) {
        guard var waiters = diskQueues[key] else { return }
        if waiters.isEmpty {
            diskQueues[key] = nil
            return
        }
        let next = waiters.removeFirst()
        diskQueues[key] = waiters
        next.resume()
    }

    /// The app can't clear the helper's own FSKit record, and turning on disk images (which loosens
    /// protection) needs an administrator.
    private func setSettings(_ new: DrivewaySettings, authorization: Data?) -> HelperResponse {
        let stored = currentSettings
        if new.allowDiskImagesForTesting, !stored.allowDiskImagesForTesting,
           !auth.verify(authorization, right: AuthorizationRights.modifyDisk)
        {
            return .error(.notAuthorized)
        }
        var s = new
        s.fskitFailedOnOSBuild = stored.fskitFailedOnOSBuild
        do {
            try saveSettings(s)
            return .ok
        } catch {
            return .error(.commandFailed("Couldn't save settings: \(error.localizedDescription)"))
        }
    }

    private func listVolumes() async -> [Volume] {
        guard let ctx = await context() else { return [] }
        var volumes: [Volume] = []
        for d in ctx.disks where Self.isValidBSDName(d.bsdName) && !Self.isEFI(d) {
            guard !ctx.policy.isProtected(d, allDisks: ctx.disks) else { continue }
            if var v = mounts[d.bsdName] {
                v.usedBytes = v.mountPoint.flatMap { inventory.usage(ofMountPoint: $0) }
                (v.diskSizeBytes, v.otherPartitionCount) = Self.diskLayout(of: d, in: ctx.disks)
                volumes.append(v)
            } else if let fs = await filesystem(of: d) {
                volumes.append(describe(d, fs))
            }
        }
        return volumes
    }

    // MARK: - Disk events

    public func diskAppeared(_ disk: DiskDescription) async -> VolumeEvent? {
        guard Self.isValidBSDName(disk.bsdName) else { return nil }
        let key = Self.lockKey(disk.bsdName)
        await lockDisk(key)
        let event = await appeared(disk)
        await releaseDisk(key)
        return event
    }

    /// The caller holds the disk's queue.
    /// A disk Driveway won't take over is always left to macOS, so a mount the approval callback refused earlier
    /// is released and asked for again.
    private func appeared(_ disk: DiskDescription) async -> VolumeEvent? {
        guard let ctx = await context() else { return await leaveToMacOS(disk, nil) }
        // Gone already: its disappearance overtook this event.
        guard let d = ctx.disks.first(where: { $0.bsdName == disk.bsdName }) else { return nil }
        guard !Self.isEFI(d), !ctx.policy.isProtected(d, allDisks: ctx.disks) else { return await leaveToMacOS(d, nil) }
        if let existing = mounts[d.bsdName] { return .mounted(existing) }

        guard let fs = await filesystem(of: d) else { return await leaveToMacOS(d, nil) }
        switch await plan(d, fs, ctx.settings, explicit: false) {
        case .backOff(let driver):
            let event = VolumeEvent.backedOff(describe(d, fs), driver: driver)
            _ = await leaveToMacOS(d, fs)
            return event
        case .leave:
            return await leaveToMacOS(d, fs)
        case .takeOver(let backend, let user):
            switch await takeOver(d, fs, backend: backend, user: user, ctx: ctx) {
            case .mounted(let v): return .mounted(v)
            case .readOnly(let v, let reason): return .mountedReadOnly(v, reason: reason)
            case .failed(let v, let message, _, _): return .mountFailed(v, message: message)
            }
        }
    }

    /// Runs the plug-in decision again for NTFS and ext partitions that Driveway doesn't hold: drives attached at
    /// the login window or before Setup was finished stay with macOS until then. Leaves out drives another driver
    /// or a FUSE mount owns, and drives known to be dirty or hibernated (they need fixing first). Each drive waits
    /// its turn in its disk's queue, as at plug-in. Returns the events to broadcast.
    public func reevaluateDrives() async -> [VolumeEvent] {
        guard let ctx = await context() else { return [] }
        var events: [VolumeEvent] = []
        for d in ctx.disks where Self.isValidBSDName(d.bsdName) && !d.isWholeMedia {
            guard mounts[d.bsdName] == nil, Self.owner(of: d) == nil, Self.ownBackend(forVolumeKind: d.volumeKind) == nil
            else { continue }
            if let health = notes[d.bsdName]?.health, health == .dirty || health == .hibernated { continue }
            guard await filesystem(of: d)?.isDrivewayManaged == true else { continue }
            let key = Self.lockKey(d.bsdName)
            await lockDisk(key)
            // Another operation may have mounted it while this waited.
            let event = mounts[d.bsdName] == nil ? await appeared(d) : nil
            await releaseDisk(key)
            if let event { events.append(event) }
        }
        return events
    }

    /// Reports the removal at once. If an operation holds the disk, forgetting waits until it finishes, so
    /// a partition that an erase removes and recreates keeps the state the operation gives it.
    public func diskDisappeared(_ bsdName: String) async -> VolumeEvent {
        if Self.isValidBSDName(bsdName), diskQueues[Self.lockKey(bsdName)] != nil {
            pendingRemovals.insert(bsdName)
        } else {
            clearRemoved(bsdName)
        }
        return .removed(bsdName: bsdName)
    }

    private func clearRemoved(_ bsdName: String) {
        forget(bsdName)
        notes[bsdName] = nil
        shared.withLock {
            $0.macOSMountAllowed.remove(bsdName)
            $0.detected[bsdName] = nil
        }
    }

    /// Called from DiskArbitration's mount-approval callback: false only when Driveway will mount the disk
    /// itself. Anything unknown (boot disks, backend) approves, so macOS's read-only mount is the fallback.
    public nonisolated func shouldApproveMacOSMount(_ disk: DiskDescription) -> Bool {
        let bsd = disk.bsdName
        guard Self.isValidBSDName(bsd) else { return true }
        // One lock, no file access: this runs on DiskArbitration's callback queue.
        let s = shared.withLock { $0 }
        // Driveway's own claim wins over everything, including a format in progress on the disk.
        if s.claimed.contains(bsd) || s.blocked.contains(bsd) { return false }
        if s.formatting.contains(Self.lockKey(bsd)) || s.macOSMountAllowed.contains(bsd) { return true }
        guard let boot = s.boot, !boot.isEmpty, case .ready = s.backend else { return true }
        let settings = s.settings
        let policy = ProtectionPolicy(bootWholeDisks: boot, allowDiskImages: settings.allowDiskImagesForTesting)
        if policy.isProtected(disk, allDisks: s.disks) { return true }
        let fs = s.detected[bsd]
            ?? FilesystemProbe.kind(forDAVolumeKind: disk.volumeKind, volumeType: disk.volumeType) ?? .other
        let action = autoMountAction(
            filesystem: fs, mountedBy: Self.owner(of: disk) ?? MountOwner.none, settingsKey: disk.settingsKey,
            settings: settings, features: features(), consoleUser: Self.loggedIn(consoleUser()))
        guard action == .mountNTFSReadWrite || action == .mountExtReadOnly else { return true }
        shared.withLock { _ = $0.blocked.insert(bsd) }
        return false
    }

    // MARK: - Helpers

    /// The volume's header first; DiskArbitration's kind only when the header says nothing or can't be read
    /// (DiskArbitration has reported a fresh NTFS partition as exFAT).
    func filesystem(of d: DiskDescription) async -> FilesystemKind? {
        let fromHeader = (try? await inventory.header(of: d.bsdName)).flatMap(FilesystemProbe.detect(header:))
        let kind = fromHeader ?? FilesystemProbe.kind(forDAVolumeKind: d.volumeKind, volumeType: d.volumeType)
        if let kind { shared.withLock { $0.detected[d.bsdName] = kind } }
        return kind
    }

    func refreshed(_ d: DiskDescription) async -> DiskDescription {
        await inventory.disks().first { $0.bsdName == d.bsdName } ?? d
    }

    /// The disk as it is now, mounted by macOS, another driver or nothing.
    func describe(_ d: DiskDescription, _ fs: FilesystemKind) -> Volume {
        let owner: MountOwner = Self.owner(of: d) ?? (d.volumePath == nil ? MountOwner.none : MountOwner.macOS)
        let access: AccessMode =
            d.volumePath == nil ? .notMounted : (owner == .macOS && fs.isDrivewayManaged ? .readOnly : .readWrite)
        let note = notes[d.bsdName]
        let layout = Self.diskLayout(of: d, in: shared.withLock { $0.disks })
        return Volume(
            bsdName: d.bsdName, wholeDisk: d.wholeDisk, label: Self.displayLabel(d), filesystem: fs,
            capacityBytes: d.sizeBytes, usedBytes: d.volumePath.flatMap { inventory.usage(ofMountPoint: $0) },
            mountPoint: d.volumePath, access: access, health: note?.health ?? .unknown, mountedBy: owner,
            deviceModel: d.deviceModel, settingsKey: d.settingsKey, lastError: note?.lastError,
            diskSizeBytes: layout.diskSizeBytes, otherPartitionCount: layout.otherPartitions)
    }

    /// The size of `d`'s whole disk, and how many other partitions it has besides `d` and the EFI system
    /// partition, whatever their filesystem: a whole-disk erase destroys them all.
    static func diskLayout(
        of d: DiskDescription, in disks: [DiskDescription]
    ) -> (diskSizeBytes: Int64?, otherPartitions: Int) {
        let size = disks.first { $0.bsdName == d.wholeDisk }?.sizeBytes
        let others = disks.filter {
            $0.wholeDisk == d.wholeDisk && $0.bsdName != d.wholeDisk && $0.bsdName != d.bsdName && !isEFI($0)
        }
        return (size, Set(others.map(\.bsdName)).count)
    }

    /// `unbounded` runs `c` without a time limit (check, repair, backup and format tools). With `progress`, the
    /// tool's output is read as it runs and turned into `.progress` events.
    func run(
        _ c: Command, unbounded: Bool = false, progress report: ProgressReport? = nil
    ) async -> Result<CommandResult, HelperError> {
        let runner = unbounded ? unboundedRunner : runner
        do {
            guard let report else { return .success(try await runner.run(c)) }
            return .success(try await runner.run(c, onOutputLine: Self.reporter(report, to: progress)))
        } catch CommandRunnerError.toolMissing(let path) {
            return .failure(.toolMissing(path))
        } catch {
            return .failure(.commandFailed(String(describing: error)))
        }
    }

    /// Which drive and operation a tool's progress is about, and how to read it from the tool's output.
    struct ProgressReport {
        var bsdName: String
        var operation: ProgressOperation
        var parser: any ProgressParsing
    }

    /// Turns output lines into `.progress` events for `sink`, about two a second.
    static func reporter(
        _ report: ProgressReport, to sink: @escaping @Sendable (VolumeEvent) -> Void
    ) -> @Sendable (String) -> Void {
        let state = Mutex((parser: report.parser, throttle: ProgressThrottle()))
        let (bsdName, operation) = (report.bsdName, report.operation)
        return { line in
            let fraction = state.withLock { s -> Double? in
                guard let f = s.parser.fraction(after: line), s.throttle.admit(f) else { return nil }
                return f
            }
            if let fraction { sink(.progress(bsdName: bsdName, operation: operation, fraction: fraction)) }
        }
    }

    /// Like `run`, but a non-zero exit is a failure carrying the tool's message.
    func runOK(_ c: Command, unbounded: Bool = false) async -> Result<CommandResult, HelperError> {
        switch await run(c, unbounded: unbounded) {
        case .success(let r) where r.exitCode == 0: .success(r)
        case .success(let r): .failure(.commandFailed(Self.message(r, c)))
        case .failure(let e): .failure(e)
        }
    }

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

    /// The whole-disk part of a valid BSD name: "disk4s2" -> "disk4". Used as the queue key.
    static func lockKey(_ bsd: String) -> String {
        "disk" + String(bsd.unicodeScalars.dropFirst(4).prefix { $0.value >= 0x30 && $0.value <= 0x39 })
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

    /// An absolute path to a file outside /dev, with no ".." components.
    static func isSafeImagePath(_ path: String) -> Bool {
        guard path.hasPrefix("/"), !path.hasSuffix("/"), !path.contains("\0"), !path.hasPrefix("/dev/") else { return false }
        return !path.split(separator: "/").contains("..")
    }

    /// Nothing at `path` yet, or a regular file to replace; never a symlink, directory or device.
    static func isReplaceableImagePath(_ path: String) -> Bool {
        var st = stat()
        guard lstat(path, &st) == 0 else { return errno == ENOENT }
        return st.st_mode & S_IFMT == S_IFREG
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
}

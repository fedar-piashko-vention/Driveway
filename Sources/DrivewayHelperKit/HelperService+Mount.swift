import DrivewayCore
import DrivewayIPC
import Foundation

/// Mounting, unmounting, ejecting, and the check, repair and backup operations that unmount a volume
/// and mount it again. Callers hold the disk's queue.
extension HelperService {
    func mount(_ d: DiskDescription, _ ctx: Context, knownFilesystem: FilesystemKind? = nil) async -> HelperResponse {
        switch await mountOutcome(d, ctx, knownFilesystem: knownFilesystem) {
        case .success(let v): .volume(v)
        case .failure(let f): .error(f.error)
        }
    }

    struct MountFailure: Error {
        var error: HelperError
        /// Driveway's mount failed, but macOS mounted the drive read-only instead.
        var readOnlyByMacOS: Bool
    }

    func mountOutcome(
        _ d: DiskDescription, _ ctx: Context, knownFilesystem: FilesystemKind? = nil
    ) async -> Result<Volume, MountFailure> {
        if let existing = mounts[d.bsdName] { return .success(existing) }
        var fs = FilesystemKind.other
        if let knownFilesystem { fs = knownFilesystem } else if let detected = await filesystem(of: d) { fs = detected }
        if case .takeOver(let backend, let user) = await plan(d, fs, ctx.settings, explicit: true) {
            switch await takeOver(d, fs, backend: backend, user: user, ctx: ctx) {
            case .mounted(let v), .readOnly(let v, _): return .success(v)
            case .failed(_, _, let e, let readOnly): return .failure(MountFailure(error: e, readOnlyByMacOS: readOnly))
            }
        }
        if d.volumePath != nil { return .success(describe(d, fs)) }
        switch await handBackToMacOS(d.bsdName) {
        case .failure(let e): return .failure(MountFailure(error: e, readOnlyByMacOS: false))
        case .success: return .success(describe(await refreshed(d), fs))
        }
    }

    func unmount(_ d: DiskDescription) async -> HelperResponse {
        guard d.volumePath != nil || mounts[d.bsdName] != nil else { return .ok }
        if case .failure(let e) = await runOK(ToolCommands.unmount(device: "/dev/\(d.bsdName)", paths: paths)) {
            return .error(e)
        }
        forget(d.bsdName)
        return .ok
    }

    func eject(_ d: DiskDescription) async -> HelperResponse {
        // The whole-disk name comes from the inventory: check it before building a /dev path from it, and
        // eject only the whole disk whose queue this operation holds.
        guard Self.isValidBSDName(d.wholeDisk), d.wholeDisk == Self.lockKey(d.bsdName) else {
            return .error(.commandFailed("The drive reported an unexpected disk name. Nothing was ejected."))
        }
        if case .failure(let e) = await runOK(ToolCommands.diskutil("eject", "/dev/\(d.wholeDisk)", paths: paths)) {
            return .error(e)
        }
        for (bsd, v) in mounts where v.wholeDisk == d.wholeDisk { forget(bsd) }
        return .ok
    }

    func fixAndMount(_ d: DiskDescription, _ ctx: Context) async -> HelperResponse {
        guard await filesystem(of: d) == .ntfs else { return .error(.commandFailed("Fix & mount is only for NTFS drives.")) }
        let wasMounted = d.volumePath != nil || mounts[d.bsdName] != nil
        if wasMounted {
            if case .failure(let e) = await runOK(ToolCommands.unmount(device: "/dev/\(d.bsdName)", paths: paths)) {
                return .error(e)
            }
            forget(d.bsdName)
        }
        if case .failure(let e) = await runOK(ToolCommands.ntfsfix(device: "/dev/\(d.bsdName)", mode: .repair, paths: paths)) {
            if wasMounted, case .failure(let mountError) = await handBackToMacOS(d.bsdName) {
                return .error(.commandFailed(
                    "\(Self.text(e)) The drive couldn't be mounted again: \(Self.text(mountError))"))
            }
            return .error(e)
        }
        var unmounted = d
        unmounted.volumePath = nil
        return await mount(unmounted, ctx, knownFilesystem: .ntfs)
    }

    func checkOrRepair(_ d: DiskDescription, _ ctx: Context, mode: CheckMode) async -> HelperResponse {
        let fs = await filesystem(of: d) ?? .other
        let device = "/dev/\(d.bsdName)"
        let result: Result<CommandResult, HelperError>
        var remountError: String?
        switch fs {
        case .exfat, .fat32, .fat16:
            result = await run(ToolCommands.diskutil(mode == .check ? "verifyVolume" : "repairVolume", device, paths: paths))
        case .ntfs:
            (result, remountError) = await whileUnmounted(d, ctx, ToolCommands.ntfsfix(device: device, mode: mode, paths: paths))
        case .ext2, .ext3, .ext4:
            (result, remountError) = await whileUnmounted(d, ctx, ToolCommands.e2fsck(device: device, mode: mode, paths: paths))
        case .other:
            return .error(.commandFailed("Check and repair aren't available for this drive's format."))
        }
        switch result {
        case .failure(let e):
            guard let remountError else { return .error(e) }
            return .error(.commandFailed("\(Self.text(e)) \(remountError)"))
        case .success(let r):
            // `succeeded` stays about the check itself; the mount problem is reported next to it.
            var report = Self.report(fs, mode: fs == .ntfs && mode == .repairForce ? .repair : mode, r)
            if let remountError {
                report.summary += " " + remountError
                report.rawOutput += (report.rawOutput.isEmpty ? "" : "\n\n") + remountError
            }
            return .report(report)
        }
    }

    func backup(_ d: DiskDescription, _ ctx: Context, imagePath: String) async -> HelperResponse {
        guard await filesystem(of: d) == .ntfs else { return .error(.commandFailed("Back up is only for NTFS drives.")) }
        guard Self.isSafeImagePath(imagePath) else { return .error(.commandFailed(Self.badImagePathMessage)) }
        let command = ToolCommands.ntfsclone(device: "/dev/\(d.bsdName)", imagePath: imagePath, paths: paths)
        let (result, remountError) = await whileUnmounted(d, ctx, command)
        let failure: String?
        switch result {
        case .failure(let e): failure = Self.text(e)
        case .success(let r): failure = r.exitCode == 0 ? nil : Self.message(r, command)
        }
        switch (failure, remountError) {
        case (nil, nil): return .ok
        case (nil, let note?): return .error(.commandFailed("The backup was saved. \(note)"))
        case (let message?, nil): return .error(.commandFailed(message))
        case (let message?, let note?): return .error(.commandFailed("\(message) \(note)"))
        }
    }

    /// Unmounts `d` if it is mounted, runs `command`, then mounts it again. The second value is a sentence
    /// describing a remount that didn't go as before: read-only by macOS, or not mounted at all.
    func whileUnmounted(
        _ d: DiskDescription, _ ctx: Context, _ command: Command
    ) async -> (Result<CommandResult, HelperError>, String?) {
        let wasMounted = d.volumePath != nil || mounts[d.bsdName] != nil
        if wasMounted {
            if case .failure(let e) = await runOK(ToolCommands.unmount(device: "/dev/\(d.bsdName)", paths: paths)) {
                return (.failure(e), nil)
            }
            forget(d.bsdName)
        }
        let result = await run(command)
        guard wasMounted else { return (result, nil) }
        var unmounted = d
        unmounted.volumePath = nil
        guard case .failure(let f) = await mountOutcome(unmounted, ctx) else { return (result, nil) }
        return (result, Self.remountNote(f))
    }

    static func remountNote(_ f: MountFailure) -> String {
        f.readOnlyByMacOS
            ? "The drive is now mounted read-only by macOS, because mounting it with Driveway failed: \(Self.text(f.error))"
            : "The drive couldn't be mounted again: \(Self.text(f.error))"
    }

    // MARK: - Taking a drive over

    enum Plan {
        case takeOver(MountBackend, ConsoleUser)
        case leave
        case backOff(String)
    }

    /// `explicit` is a user's Mount click: the auto-mount switch doesn't apply, the per-drive read-only one does.
    func plan(_ d: DiskDescription, _ fs: FilesystemKind, _ settings: DrivewaySettings, explicit: Bool) async -> Plan {
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

    enum MountResult {
        case mounted(Volume)
        case readOnly(Volume, ReadOnlyReason)
        /// The last value: macOS mounted the drive read-only instead.
        case failed(Volume, String, HelperError, readOnlyByMacOS: Bool)
    }

    func takeOver(
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
                return .failed(v, Self.text(e), e, readOnlyByMacOS: false)
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
            var readOnly = false
            if fs == .ntfs { readOnly = await handBack(bsd) } else { release(bsd) }
            return .failed(v, Self.text(e), e, readOnlyByMacOS: readOnly)
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
            if backend == .fskit { recordFSKitFailure() }
            let message = "The drive didn't appear in Finder after mounting."
            let readOnly = await handBack(bsd)
            v.lastError = message
            return .failed(v, message, .commandFailed(message), readOnlyByMacOS: readOnly)
        }

        guard fs == .ntfs else {
            release(bsd)
            let message = Self.message(result, command)
            v.lastError = message
            return .failed(v, message, .commandFailed(message), readOnlyByMacOS: false)
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
            return .failed(v, fallback.reason ?? Self.text(e), e, readOnlyByMacOS: false)
        }
        var ro = describe(await refreshed(d), fs)
        ro.mountedBy = .macOS
        ro.access = .readOnly
        return .readOnly(ro, reason)
    }

    /// FSKit exited 0 but nothing mounted. Remembered in memory first, so a failed save can't make the
    /// next probe try FSKit again on this build.
    func recordFSKitFailure() {
        fskitFailedThisBuild = true
        shared.withLock { $0.backend = .unavailable }
        var s = store.load()
        s.fskitFailedOnOSBuild = osBuild
        do {
            try store.save(s)
        } catch {
            log("Couldn't save the FSKit failure for \(osBuild): \(error.localizedDescription)")
        }
    }

    /// Hands the disk back to macOS; true when macOS mounted it.
    func handBack(_ bsd: String) async -> Bool {
        if case .success = await handBackToMacOS(bsd) { return true }
        return false
    }

    /// Lets macOS mount the disk (read-only for NTFS) and asks it to.
    func handBackToMacOS(_ bsd: String) async -> Result<CommandResult, HelperError> {
        release(bsd)
        return await runOK(ToolCommands.diskutil("mount", "/dev/\(bsd)", paths: paths))
    }

    /// Leaves the disk to macOS. If the approval callback refused macOS's mount earlier, asks macOS to mount
    /// it now; if that fails, the failure is the event.
    func leaveToMacOS(_ d: DiskDescription, _ fs: FilesystemKind?) async -> VolumeEvent? {
        let wasBlocked = shared.withLock { $0.blocked.contains(d.bsdName) }
        guard wasBlocked, d.volumePath == nil else {
            release(d.bsdName)
            return nil
        }
        guard case .failure(let e) = await handBackToMacOS(d.bsdName) else { return nil }
        var v = describe(d, fs ?? .other)
        v.lastError = Self.text(e)
        return .mountFailed(v, message: Self.text(e))
    }

    func release(_ bsd: String) {
        shared.withLock {
            $0.claimed.remove(bsd)
            $0.blocked.remove(bsd)
            $0.macOSMountAllowed.insert(bsd)
        }
    }

    func forget(_ bsd: String) {
        mounts[bsd] = nil
        shared.withLock {
            $0.claimed.remove(bsd)
            $0.blocked.remove(bsd)
        }
    }

    func backendAvailability() async -> BackendAvailability {
        let p = await backendProbe.probe()
        let failedHere = fskitFailedThisBuild || store.load().fskitFailedOnOSBuild == osBuild
        let availability = BackendPolicy.availability(
            kextsAllowed: p.kextsAllowed, kextApproved: p.kextApproved, fskitEnabled: p.fskitEnabled,
            fskitFailedOnThisOS: failedHere)
        shared.withLock { $0.backend = availability }
        return availability
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
            case .corrected, .correctedNeedsReboot: (succeeded, summary) = (true, "Problems were found and fixed.")
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

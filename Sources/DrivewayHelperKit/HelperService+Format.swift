import DrivewayCore
import DrivewayIPC
import Foundation

extension HelperService {
    /// Name check, queue, lookup, EFI refusal, identity, `validate`, protection, authorization, then the erase step, a fresh disk
    /// list, the data partition (refused if missing or EFI), the finish step, and a mount of NTFS or ext.
    func format(_ r: FormatRequest, authorization: Data?) async -> HelperResponse {
        let target: String
        let wholeDiskTarget: Bool
        switch r.target {
        case .wholeDisk(let name): (target, wholeDiskTarget) = (name, true)
        case .partition(let name): (target, wholeDiskTarget) = (name, false)
        }
        guard Self.isValidBSDName(target) else { return .error(.unknownVolume) }
        // Checked before waiting for the disk: the administrator's credential is only good for the right's timeout.
        let authorized = auth.verify(authorization, right: AuthorizationRights.modifyDisk)
        let key = Self.lockKey(target)
        await lockDisk(key)
        let response = await formatHeld(r, target: target, wholeDiskTarget: wholeDiskTarget, key: key, authorized: authorized)
        await releaseDisk(key)
        return response
    }

    /// The caller holds the queue for `key`.
    private func formatHeld(
        _ r: FormatRequest, target: String, wholeDiskTarget: Bool, key: String, authorized: Bool
    ) async -> HelperResponse {

        guard let ctx = await context() else { return .error(.protectedDisk) }
        guard let d = ctx.disks.first(where: { $0.bsdName == target }) else { return .error(.unknownVolume) }
        // The EFI system partition is never a target, whatever else the request says.
        if Self.isEFI(d) { return .error(.protectedDisk) }
        // The drive must still be the one the user chose: for a whole disk, a volume on it (or the disk) has the key.
        let identified: Bool
        switch r.target {
        case .partition: identified = identityMatches(d, key: r.expectedKey)
        case .wholeDisk:
            identified = ctx.disks.contains { $0.wholeDisk == d.wholeDisk && identityMatches($0, key: r.expectedKey) }
        }
        guard identified else { return .error(.unknownVolume) }
        do throws(FormatValidationError) {
            try validate(r, currentDriveName: Self.confirmationName(for: r, target: d, in: ctx.disks))
        } catch {
            return .error(.validation(error))
        }
        if ctx.policy.isProtected(d, allDisks: ctx.disks) { return .error(.protectedDisk) }
        guard authorized else { return .error(.notAuthorized) }

        // What was known about the erased volumes is about to be wrong. Until Driveway mounts the result,
        // macOS may mount new volumes on this disk (the temporary ExFAT volume, a new exFAT/FAT volume).
        // Partitions that aren't erased keep their state, including a refused macOS mount.
        let erased: Set<String> =
            wholeDiskTarget
            ? Set(ctx.disks.filter { $0.wholeDisk == d.wholeDisk }.map(\.bsdName)).union([target]) : [target]
        for bsd in erased { forget(bsd) }
        shared.withLock { s in
            s.formatting.insert(key)
            for bsd in erased {
                s.detected[bsd] = nil
                s.blocked.remove(bsd)
                s.claimed.remove(bsd)
                s.macOSMountAllowed.insert(bsd)
            }
        }
        defer { shared.withLock { _ = $0.formatting.remove(key) } }

        for c in FormatPlanner.eraseCommands(r, paths: paths) {
            if case .failure(let e) = await runOK(c, unbounded: true) { return .error(e) }
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
        guard Self.isValidBSDName(dataName), Self.lockKey(dataName) == key else {
            return .error(.commandFailed("The drive reported an unexpected partition name. Nothing was formatted."))
        }
        guard !Self.isEFI(data) else {
            return .error(.commandFailed("The target is now an EFI system partition. Nothing was formatted."))
        }
        if ctx.policy.isProtected(data, allDisks: fresh) { return .error(.protectedDisk) }
        let finish = FormatPlanner.finishCommands(r, dataPartition: dataName, paths: paths)
        guard !finish.isEmpty else { return .error(.commandFailed("Couldn't plan the format. Nothing was formatted.")) }
        for c in finish {
            if case .failure(let e) = await runOK(c, unbounded: true) { return .error(e) }
        }

        // Claim the new volume before the format mark goes, so macOS can't mount it ahead of Driveway.
        // Every path through `mount` either keeps the claim (mounted) or releases it to macOS.
        shared.withLock { s in
            s.claimed.insert(dataName)
            s.macOSMountAllowed.remove(dataName)
            s.formatting.remove(key)
        }
        var formatted = data
        formatted.volumePath = nil
        formatted.volumeName = r.label
        var freshCtx = ctx
        freshCtx.disks = fresh
        switch await mount(formatted, freshCtx, knownFilesystem: r.filesystem) {
        case .volume(let v?): return .volume(v)
        case .error(let e): return .error(.commandFailed(Self.formattedButNotMounted + Self.text(e)))
        default: return .error(.commandFailed(Self.formattedButNotMounted + "no volume."))
        }
    }

    static let formattedButNotMounted = "The drive was formatted, but mounting it failed: "

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
}

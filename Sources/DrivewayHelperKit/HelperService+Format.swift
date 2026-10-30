import DrivewayCore
import DrivewayIPC
import Foundation

extension HelperService {
    /// Name check, queue, lookup, `validate`, protection, authorization, then the erase step, a fresh disk
    /// list, the data partition (refused if missing or EFI), the finish step, and a mount of NTFS or ext.
    func format(_ r: FormatRequest, authorization: Data?) async -> HelperResponse {
        let target: String
        let wholeDiskTarget: Bool
        switch r.target {
        case .wholeDisk(let name): (target, wholeDiskTarget) = (name, true)
        case .partition(let name): (target, wholeDiskTarget) = (name, false)
        }
        guard Self.isValidBSDName(target) else { return .error(.unknownVolume) }
        let key = Self.lockKey(target)
        await lockDisk(key)
        defer { unlockDisk(key) }

        guard let ctx = await context() else { return .error(.protectedDisk) }
        guard let d = ctx.disks.first(where: { $0.bsdName == target }) else { return .error(.unknownVolume) }
        do throws(FormatValidationError) {
            try validate(r, currentDriveName: Self.confirmationName(for: r, target: d, in: ctx.disks))
        } catch {
            return .error(.validation(error))
        }
        if ctx.policy.isProtected(d, allDisks: ctx.disks) { return .error(.protectedDisk) }
        guard auth.verify(authorization, right: AuthorizationRights.modifyDisk) else { return .error(.notAuthorized) }

        // Whatever was known about these volumes is about to be wrong. Until Driveway mounts the result,
        // macOS may mount anything on this disk (the temporary ExFAT volume, a new exFAT/FAT volume).
        let onDisk = Set(ctx.disks.filter { $0.wholeDisk == d.wholeDisk }.map(\.bsdName)).union([target])
        let erased = wholeDiskTarget ? onDisk : [target]
        for bsd in erased { forget(bsd) }
        let reset = onDisk.filter { mounts[$0] == nil }
        shared.withLock { s in
            s.formatting.insert(key)
            for bsd in reset {
                s.detected[bsd] = nil
                s.blocked.remove(bsd)
                s.claimed.remove(bsd)
                s.macOSMountAllowed.insert(bsd)
            }
        }
        defer { shared.withLock { _ = $0.formatting.remove(key) } }

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
            if case .failure(let e) = await runOK(c) { return .error(e) }
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

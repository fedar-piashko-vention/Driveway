import DiskArbitration
import DrivewayCore
import DrivewayIPC
import Foundation
import Synchronization
import os

/// Feeds DiskArbitration's disk events to the helper service on a serial queue of its own.
///
/// Callbacks never block. Appeared and disappeared events start a task that calls the service (which may
/// wait up to 30 minutes behind an operation on the same disk) and then broadcasts the result. The mount
/// approval callback must answer synchronously, so it only calls `shouldApproveMacOSMount`, which takes
/// one lock and reads nothing from disk.
public final class DiskWatcher: @unchecked Sendable {
    private let session: DASession
    private let queue = DispatchQueue(label: "app.driveway.helper.disk-arbitration")
    private let broadcast: @Sendable (VolumeEvent) -> Void
    private let logger: Logger
    /// Set once by `start(service:)`, before any callback is registered.
    private var service: HelperService!
    private let loggedOwnMount = Mutex(false)

    public init?(broadcast: @escaping @Sendable (VolumeEvent) -> Void, logger: Logger) {
        guard let session = DASessionCreate(kCFAllocatorDefault) else { return nil }
        self.session = session
        self.broadcast = broadcast
        self.logger = logger
    }

    /// Registers the callbacks and starts delivering events. Call once; the watcher lives as long as the process.
    public func start(service: HelperService) {
        self.service = service
        // The callbacks' context. Retained for good: DiskArbitration keeps calling back until exit.
        let context = Unmanaged.passRetained(self).toOpaque()
        let partitions = [kDADiskDescriptionMediaWholeKey as String: false] as CFDictionary

        DARegisterDiskAppearedCallback(session, partitions, { disk, context in
            DiskWatcher.unwrap(context)?.appeared(disk)
        }, context)
        DARegisterDiskDisappearedCallback(session, nil, { disk, context in
            DiskWatcher.unwrap(context)?.disappeared(disk)
        }, context)
        DARegisterDiskMountApprovalCallback(session, nil, { disk, context in
            DiskWatcher.unwrap(context)?.approveMount(disk)
        }, context)
        DASessionSetDispatchQueue(session, queue)
    }

    private static func unwrap(_ context: UnsafeMutableRawPointer?) -> DiskWatcher? {
        context.map { Unmanaged<DiskWatcher>.fromOpaque($0).takeUnretainedValue() }
    }

    static func description(of disk: DADisk) -> DiskDescription? {
        guard let bsd = DADiskGetBSDName(disk).map({ String(cString: $0) }),
              let raw = DADiskCopyDescription(disk) as? [String: Any]
        else { return nil }
        return DiskDescription(daDescription: raw, bsdName: bsd)
    }

    private func appeared(_ disk: DADisk) {
        guard let d = Self.description(of: disk) else { return }
        let service = self.service!
        let broadcast = self.broadcast
        Task {
            if let event = await service.diskAppeared(d) { broadcast(event) }
        }
    }

    private func disappeared(_ disk: DADisk) {
        guard let bsd = DADiskGetBSDName(disk).map({ String(cString: $0) }) else { return }
        let service = self.service!
        let broadcast = self.broadcast
        Task {
            broadcast(await service.diskDisappeared(bsd))
        }
    }

    /// Nil approves. Driveway's own mounts always pass.
    private func approveMount(_ disk: DADisk) -> Unmanaged<DADissenter>? {
        guard let d = Self.description(of: disk) else { return nil }
        if HelperService.ownVolumeKinds.contains(d.volumeKind?.lowercased() ?? "") {
            let first = loggedOwnMount.withLock { logged in
                defer { logged = true }
                return !logged
            }
            if first {
                logger.info("Approved Driveway's own mount: \(String(describing: d), privacy: .public)")
            }
            return nil
        }
        guard !service.shouldApproveMacOSMount(d) else { return nil }
        logger.info("Refused macOS's mount of \(d.bsdName, privacy: .public): Driveway mounts it.")
        let dissenter = DADissenterCreate(
            kCFAllocatorDefault, DAReturn(kDAReturnNotPermitted), "Driveway mounts this drive." as CFString)
        return Unmanaged.passRetained(dissenter)
    }
}

import DrivewayCore
import Foundation

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
    /// Whether the volume mounted at `mountPoint` is read-only; nil when nothing is mounted there.
    func mountIsReadOnly(_ mountPoint: String) -> Bool?
    /// True when the mount table still has an entry from `device` or on one of `mountPoints`, after giving an
    /// unmount that just finished a moment to show.
    func isStillMounted(device: String, mountPoints: [String]) async -> Bool
    /// The mount table's entry for a volume mounted from `device` (a FUSE mount's "from" name is the `fsname`
    /// Driveway sets): its mount point and filesystem type, e.g. "macfuse". Nil when nothing is mounted from it.
    func mountEntry(fromDevice device: String) -> MountEntry?
}

public struct MountEntry: Equatable, Sendable {
    public var mountPoint: String
    public var type: String
    public init(mountPoint: String, type: String) {
        self.mountPoint = mountPoint
        self.type = type
    }
}

extension DiskInventoryProviding {
    public func mountIsReadOnly(_ mountPoint: String) -> Bool? { nil }
    public func mountEntry(fromDevice device: String) -> MountEntry? { nil }
}

public protocol BackendProbing: Sendable {
    func probe() async -> (kextsAllowed: Bool, kextApproved: Bool, fskitEnabled: Bool)
}

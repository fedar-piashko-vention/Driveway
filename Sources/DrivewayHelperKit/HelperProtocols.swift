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
}

public protocol BackendProbing: Sendable {
    func probe() async -> (kextsAllowed: Bool, kextApproved: Bool, fskitEnabled: Bool)
}

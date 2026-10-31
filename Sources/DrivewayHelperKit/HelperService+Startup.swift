import DrivewayCore
import DrivewayIPC
import Foundation

extension HelperService {
    /// DiskArbitration volume kinds of Driveway's own mounts. "macfuse" is the kernel backend's mount type
    /// (spike) and also the FSShortName of macFUSE's FSKit module; "macfuse-local" is the FSShortName of the
    /// FSKit module Driveway uses (`io.macfuse.app.fsmodule.macfuse-local`).
    public static let ownVolumeKinds: Set<String> = ["macfuse", "macfuse-local"]

    /// The backend behind a volume of this kind, or nil if Driveway didn't mount it.
    static func ownBackend(forVolumeKind kind: String?) -> MountBackend? {
        switch kind?.lowercased() {
        case "macfuse": .kernel
        case "macfuse-local": .fskit
        default: nil
        }
    }

    /// Called once at startup, before the disk watcher starts. Volumes Driveway mounted before the helper
    /// restarted are still mounted: record them as Driveway's (claimed, so macOS isn't let in, and so a
    /// Mount request doesn't mount them twice). Protected disks are left alone.
    public func adoptExistingMounts() async {
        guard let ctx = await context() else { return }
        for d in ctx.disks where Self.isValidBSDName(d.bsdName) {
            guard mounts[d.bsdName] == nil, !ctx.policy.isProtected(d, allDisks: ctx.disks) else { continue }
            // DiskArbitration's volume kind is no proof of ownership: for an NTFS partition it says "ntfs" (Apple's
            // probe recognised it) even when ntfs-3g mounted it, and for ext it knows no mount at all. The mount
            // table's filesystem type ("macfuse") is.
            let entry = inventory.mountEntry(fromDevice: "/dev/\(d.bsdName)")
            guard let backend = Self.ownBackend(forVolumeKind: d.volumeKind)
                ?? entry.flatMap({ Self.ownBackend(forVolumeKind: $0.type) }),
                let mountPoint = d.volumePath ?? entry?.mountPoint
            else { continue }
            let fs = await filesystem(of: d) ?? .other
            // ext4fuse only reads, though its mounts don't carry the read-only flag.
            let readOnly = fs != .ntfs || (inventory.mountIsReadOnly(mountPoint) ?? false)
            var v = describe(d, fs)
            v.mountPoint = mountPoint
            v.access = readOnly ? .readOnly : .readWrite
            // Nothing was checked: the volume was mounted before this helper started.
            v.health = .unknown
            v.mountedBy = .driveway
            v.backend = backend
            v.lastError = nil
            mounts[d.bsdName] = v
            notes[d.bsdName] = nil
            shared.withLock {
                $0.claimed.insert(d.bsdName)
                $0.macOSMountAllowed.remove(d.bsdName)
            }
            log("Adopted \(d.bsdName) at \(mountPoint) (\(fs.rawValue), \(backend), \(readOnly ? "read-only" : "read/write"))")
        }
    }
}

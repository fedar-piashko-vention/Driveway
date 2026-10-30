import CoreFoundation
import DiskArbitration
import DrivewayCore
import Foundation
import IOKit

extension DiskDescription {
    /// Maps a DiskArbitration description (`DADiskCopyDescription`). Missing keys give nil, false, 0 or "".
    /// `DAVolumeUUID` and `DAMediaUUID` may be CFUUIDs or strings; `DAVolumePath` is a URL.
    public init(daDescription d: [String: Any], bsdName: String) {
        let name = (d["DAMediaBSDName"] as? String) ?? bsdName
        let model = (d["DADeviceModel"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        self.init(
            bsdName: name,
            wholeDisk: Self.wholeDisk(of: name),
            isWholeMedia: (d["DAMediaWhole"] as? Bool) ?? false,
            isInternal: (d["DADeviceInternal"] as? Bool) ?? false,
            isDiskImage: model == "Disk Image",
            volumeKind: d["DAVolumeKind"] as? String,
            volumeType: d["DAVolumeType"] as? String,
            contentType: d["DAMediaContent"] as? String,
            volumeName: d["DAVolumeName"] as? String,
            volumeUUID: Self.uuidString(d["DAVolumeUUID"]),
            mediaUUID: Self.uuidString(d["DAMediaUUID"]),
            sizeBytes: (d["DAMediaSize"] as? NSNumber)?.int64Value ?? 0,
            deviceModel: model,
            volumePath: Self.path(d["DAVolumePath"]))
    }

    /// "disk4s1" -> "disk4"; a name that isn't `disk<N>...` is its own whole disk.
    static func wholeDisk(of bsd: String) -> String {
        guard bsd.hasPrefix("disk") else { return bsd }
        let digits = bsd.dropFirst(4).prefix { $0.isASCII && $0.isNumber }
        return digits.isEmpty ? bsd : "disk" + digits
    }

    static func uuidString(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let s = value as? String { return s }
        let object = value as AnyObject
        guard CFGetTypeID(object) == CFUUIDGetTypeID() else { return nil }
        return CFUUIDCreateString(kCFAllocatorDefault, unsafeDowncast(object, to: CFUUID.self)) as String?
    }

    static func path(_ value: Any?) -> String? {
        if let url = value as? URL { return url.path }
        if let s = value as? String { return s }
        return nil
    }
}

/// The real disk list, from DiskArbitration descriptions of every IOMedia object with a BSD name.
public final class DADiskInventory: DiskInventoryProviding, @unchecked Sendable {
    // DASession is a CF object: immutable after creation and safe to share.
    private let session: DASession
    private let runner: any CommandRunning
    private let paths: ToolPaths

    public init?(runner: any CommandRunning, paths: ToolPaths) {
        guard let session = DASessionCreate(kCFAllocatorDefault) else { return nil }
        self.session = session
        self.runner = runner
        self.paths = paths
    }

    public func disks() async -> [DiskDescription] {
        Self.bsdNames().compactMap { name in
            guard let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, name),
                  let description = DADiskCopyDescription(disk) as? [String: Any]
            else { return nil }
            return DiskDescription(daDescription: description, bsdName: name)
        }
    }

    /// BSD names of all IOMedia objects that match `disk<N>` or `disk<N>s<M>`, sorted.
    static func bsdNames() -> [String] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOMedia"), &iterator) == KERN_SUCCESS
        else { return [] }
        defer { IOObjectRelease(iterator) }
        var names: [String] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            let property = IORegistryEntryCreateCFProperty(service, "BSD Name" as CFString, kCFAllocatorDefault, 0)
            if let name = property?.takeRetainedValue() as? String, HelperService.isValidBSDName(name) {
                names.append(name)
            }
        }
        return names.sorted()
    }

    public enum HeaderError: Error {
        case invalidName
        case openFailed(Int32)
        case readFailed(Int32)
    }

    /// The first 4096 bytes of `/dev/r<bsd>`, opened read-only. The name is checked first.
    public func header(of bsdName: String) async throws -> Data {
        guard HelperService.isValidBSDName(bsdName) else { throw HeaderError.invalidName }
        let fd = open("/dev/r\(bsdName)", O_RDONLY)
        guard fd >= 0 else { throw HeaderError.openFailed(errno) }
        defer { close(fd) }
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = buffer.withUnsafeMutableBytes { pread(fd, $0.baseAddress, $0.count, 0) }
        guard count >= 0 else { throw HeaderError.readFailed(errno) }
        return Data(buffer.prefix(count))
    }

    /// Whole disks behind `/`, from `diskutil info -plist /`. Empty on any failure (the helper then fails closed).
    public func bootWholeDisks() async -> Set<String> {
        let command = Command(executable: paths.diskutil, arguments: ["info", "-plist", "/"])
        guard let r = try? await runner.run(command), r.exitCode == 0 else { return [] }
        return ProtectionPolicy.bootWholeDisks(fromDiskutilInfoPlist: Data(r.stdout.utf8))
    }

    public func usage(ofMountPoint mountPoint: String) -> Int64? {
        var s = statfs()
        guard statfs(mountPoint, &s) == 0, Self.string(fromMountName: s.f_mntonname) == mountPoint else { return nil }
        return Int64(s.f_blocks - s.f_bfree) * Int64(s.f_bsize)
    }

    /// Polls the mount table every 250 ms for up to 5 seconds.
    public func isMounted(at mountPoint: String) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while true {
            if Self.mountEntry(at: mountPoint) != nil { return true }
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    public func mountIsReadOnly(_ mountPoint: String) -> Bool? {
        Self.mountEntry(at: mountPoint).map { $0.f_flags & UInt32(MNT_RDONLY) != 0 }
    }

    /// The mount table entry whose mount point is `mountPoint`. Uses `getfsstat` with MNT_NOWAIT, which
    /// doesn't ask the filesystems anything (a stuck FUSE daemon can't block it) and, unlike `getmntinfo`,
    /// uses a buffer of its own.
    static func mountEntry(at mountPoint: String) -> statfs? {
        let count = getfsstat(nil, 0, MNT_NOWAIT)
        guard count > 0 else { return nil }
        // Room for mounts that appear between the two calls.
        let capacity = Int(count) + 16
        let entries = UnsafeMutablePointer<statfs>.allocate(capacity: capacity)
        defer { entries.deallocate() }
        let filled = getfsstat(entries, Int32(capacity * MemoryLayout<statfs>.stride), MNT_NOWAIT)
        guard filled > 0 else { return nil }
        return UnsafeBufferPointer(start: entries, count: Int(filled)).first {
            string(fromMountName: $0.f_mntonname) == mountPoint
        }
    }

    static func string<T>(fromMountName tuple: T) -> String {
        withUnsafeBytes(of: tuple) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}

// Spike Step 5 (risk 3): does DiskArbitration's mount-approval callback see NTFS volumes,
// can it block macOS's own read-only NTFS mount, and does it also fire for our FSKit mount?
//
// Run:   swift scripts/spike/da-approval.swift              (dissents for DAVolumeKind == "ntfs")
//        swift scripts/spike/da-approval.swift --log-only   (logs only, never dissents)
// Stop with Ctrl-C. If no callbacks arrive at all, try again with sudo.
//
// NOTE: written without being compiled (Swift tooling was broken when this was authored).
import Foundation
import DiskArbitration

setvbuf(stdout, nil, _IOLBF, 0)

let blockedKind = "ntfs"

func isLogOnly() -> Bool {
    return CommandLine.arguments.contains("--log-only")
}

func log(_ message: String) {
    print("[\(ISO8601DateFormatter().string(from: Date()))] \(message)")
}

func description(of disk: DADisk) -> [String: Any] {
    guard let desc = DADiskCopyDescription(disk) as? [String: Any] else { return [:] }
    return desc
}

func stringValue(_ desc: [String: Any], _ key: String) -> String {
    if let value = desc[key] { return "\(value)" }
    return "<nil>"
}

// Logs the four keys we care about, then every key of the description.
func logDescription(_ desc: [String: Any]) {
    for key in ["DAVolumeKind", "DAVolumePath", "DAMediaBSDName", "DADeviceModel"] {
        log("    \(key) = \(stringValue(desc, key))")
    }
    log("    --- full description ---")
    for key in desc.keys.sorted() {
        log("    \(key) = \(stringValue(desc, key))")
    }
}

guard let session = DASessionCreate(kCFAllocatorDefault) else {
    log("DASessionCreate failed")
    exit(1)
}

// Disk appeared (fires for every disk, mounted or not).
DARegisterDiskAppearedCallback(session, nil, { disk, _ in
    let desc = description(of: disk)
    log("DISK APPEARED  bsd=\(stringValue(desc, "DAMediaBSDName"))  kind=\(stringValue(desc, "DAVolumeKind"))")
    logDescription(desc)
}, nil)

// Disk disappeared.
DARegisterDiskDisappearedCallback(session, nil, { disk, _ in
    let desc = description(of: disk)
    log("DISK GONE      bsd=\(stringValue(desc, "DAMediaBSDName"))  kind=\(stringValue(desc, "DAVolumeKind"))")
}, nil)

// Description changed: fires when a disk gains/changes attributes, e.g. DAVolumePath appearing
// once the FSKit mount completes on a disk that was attached with -nomount. watch = nil means all keys.
DARegisterDiskDescriptionChangedCallback(session, nil, nil, { disk, keys, _ in
    let desc = description(of: disk)
    log("DESCRIPTION CHANGED  bsd=\(stringValue(desc, "DAMediaBSDName"))  kind=\(stringValue(desc, "DAVolumeKind"))  changedKeys=\(keys)")
    logDescription(desc)
}, nil)

// Mount approval: return nil to allow, or a retained DADissenter to block.
DARegisterDiskMountApprovalCallback(session, nil, { disk, _ in
    let desc = description(of: disk)
    let kind = stringValue(desc, "DAVolumeKind")
    let blocking = !isLogOnly() && kind == blockedKind
    log("MOUNT APPROVAL bsd=\(stringValue(desc, "DAMediaBSDName"))  kind=\(kind)  decision=\(blocking ? "DISSENT" : "allow")")
    logDescription(desc)
    if blocking {
        let dissenter = DADissenterCreate(kCFAllocatorDefault, DAReturn(kDAReturnNotPermitted), "Driveway spike: NTFS read-only mount blocked" as CFString)
        return Unmanaged.passRetained(dissenter)
    }
    return nil
}, nil)

DASessionScheduleWithRunLoop(session, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

signal(SIGINT, SIG_IGN)
let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigint.setEventHandler {
    log("Ctrl-C received, exiting")
    exit(0)
}
sigint.resume()

log("Watching DiskArbitration. mode=\(isLogOnly() ? "log-only" : "dissent for DAVolumeKind == \(blockedKind)"). Ctrl-C to stop.")
CFRunLoopRun()

// driveway_ext.util: DiskArbitration's probe for ext2/3/4 partitions, in /Library/Filesystems/driveway_ext.fs.
// diskarbitrationd runs it as root with `-p disk6s1 removable readonly` (print the label) and `-k disk6s1`
// (print the UUID). It reads the superblock and nothing else: it never mounts or writes.
import DrivewayCore
import Darwin
import Foundation

// <sys/loadable_fs.h>
let recognized: Int32 = -1
let unrecognized: Int32 = -2
let ioSuccess: Int32 = -3
let ioFail: Int32 = -4
let invalidArgument: Int32 = -6

func readHeader(_ path: String) -> Data? {
    let fd = open(path, O_RDONLY)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var buffer = [UInt8](repeating: 0, count: ExtProbe.headerLength)
    let count = buffer.withUnsafeMutableBytes { pread(fd, $0.baseAddress, $0.count, 0) }
    return count > 0 ? Data(buffer.prefix(count)) : nil
}

let args = CommandLine.arguments
guard args.count >= 3, let device = ExtProbe.rawDevicePath(forBSDName: args[2]) else { exit(invalidArgument) }
switch args[1] {
case "-p":
    guard let header = readHeader(device) else { exit(ioFail) }
    guard let superblock = ExtProbe.superblock(header: header) else { exit(unrecognized) }
    if !superblock.label.isEmpty { print(superblock.label) }
    exit(recognized)
case "-k":
    guard let header = readHeader(device) else { exit(ioFail) }
    guard let uuid = ExtProbe.superblock(header: header)?.uuid else { exit(ioFail) }
    print(uuid.uuidString)
    exit(ioSuccess)
default:
    exit(invalidArgument)
}

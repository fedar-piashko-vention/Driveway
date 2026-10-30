import DrivewayCore
import DrivewayHelperKit
import DrivewayIPC
import Foundation
import Testing

@Test func consoleUserMapping() {
    #expect(HelperEnvironment.consoleUser(name: "fedar", uid: 501, gid: 20) == ConsoleUser(uid: 501, gid: 20))
    #expect(HelperEnvironment.consoleUser(name: "loginwindow", uid: 501, gid: 20) == nil)
    #expect(HelperEnvironment.consoleUser(name: "root", uid: 0, gid: 0) == nil)
    #expect(HelperEnvironment.consoleUser(name: nil, uid: 501, gid: 20) == nil)
}

@Test func osBuildIsRead() {
    #expect(HelperEnvironment.osBuild() != "unknown")
}

@Test func helperToolInventory() throws {
    let plist = try PropertyListSerialization.data(
        fromPropertyList: ["CFBundleVersion": "5.5.0"], format: .xml, options: 0)
    let paths = ToolPaths()
    let present: Set<String> = [paths.brew, paths.ntfs3g]
    let inv = HelperEnvironment.toolInventory(
        paths: paths, backend: .ready(.kernel), fileExists: { present.contains($0) }, macFUSEInfoPlist: plist,
        filesystemBundles: ["macfuse.fs", "tuxera_ntfs.fs"])
    #expect(inv.hasHomebrew && inv.hasNTFS3G)
    #expect(!inv.hasExt4fuse && !inv.hasE2fsprogs)
    #expect(inv.macFUSEVersion == SemanticVersion(major: 5, minor: 5, patch: 0))
    #expect(inv.backend == .ready(.kernel))
    #expect(inv.helperVersion == helperProtocolVersion && inv.appVersion == helperProtocolVersion)
    #expect(inv.conflictingDrivers == ["Tuxera NTFS"])
    #expect(featureStates(inv)[.writeNTFS] == .ready)

    let bare = HelperEnvironment.toolInventory(
        paths: paths, backend: .unavailable, fileExists: { _ in false }, macFUSEInfoPlist: nil, filesystemBundles: [])
    #expect(bare.macFUSEVersion == nil)
}

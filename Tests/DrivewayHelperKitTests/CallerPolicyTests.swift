import DrivewayHelperKit
import Foundation
import Testing

private let appPath = "/Applications/Driveway.app/Contents/MacOS/Driveway"
private let agentPath = "/Applications/Driveway.app/Contents/Library/LoginItems/DrivewayAgent.app/Contents/MacOS/DrivewayAgent"

@Test func callerPolicy() {
    let ok = CallerPolicy.accept(signingIdentifier: "app.driveway.Driveway", executablePath: appPath, bundleOwnerUID: 0, bundleWritableByNonRoot: false, hasHardenedRuntime: true, hasDangerousEntitlements: false)
    #expect(ok)
    #expect(CallerPolicy.accept(signingIdentifier: "app.driveway.agent", executablePath: agentPath, bundleOwnerUID: 0, bundleWritableByNonRoot: false, hasHardenedRuntime: true, hasDangerousEntitlements: false))
    #expect(!CallerPolicy.accept(signingIdentifier: "app.driveway.Driveway", executablePath: "/Users/x/Driveway.app/Contents/MacOS/Driveway", bundleOwnerUID: 0, bundleWritableByNonRoot: false, hasHardenedRuntime: true, hasDangerousEntitlements: false))
    #expect(!CallerPolicy.accept(signingIdentifier: "app.driveway.Driveway", executablePath: appPath, bundleOwnerUID: 501, bundleWritableByNonRoot: false, hasHardenedRuntime: true, hasDangerousEntitlements: false))
    #expect(!CallerPolicy.accept(signingIdentifier: "evil", executablePath: appPath, bundleOwnerUID: 0, bundleWritableByNonRoot: false, hasHardenedRuntime: true, hasDangerousEntitlements: false))
}

@Test func callerPolicyRejectsWeakerCases() {
    // A bundle anyone but root can write to.
    #expect(!CallerPolicy.accept(signingIdentifier: "app.driveway.Driveway", executablePath: appPath, bundleOwnerUID: 0, bundleWritableByNonRoot: true, hasHardenedRuntime: true, hasDangerousEntitlements: false))
    // No signing identifier.
    #expect(!CallerPolicy.accept(signingIdentifier: nil, executablePath: appPath, bundleOwnerUID: 0, bundleWritableByNonRoot: false, hasHardenedRuntime: true, hasDangerousEntitlements: false))
    // Identifier and path must belong together.
    #expect(!CallerPolicy.accept(signingIdentifier: "app.driveway.agent", executablePath: appPath, bundleOwnerUID: 0, bundleWritableByNonRoot: false, hasHardenedRuntime: true, hasDangerousEntitlements: false))
    #expect(!CallerPolicy.accept(signingIdentifier: "app.driveway.Driveway", executablePath: agentPath, bundleOwnerUID: 0, bundleWritableByNonRoot: false, hasHardenedRuntime: true, hasDangerousEntitlements: false))
    // Paths that only look right.
    #expect(!CallerPolicy.accept(signingIdentifier: "app.driveway.Driveway", executablePath: "/Applications/Driveway.app/Contents/MacOS/../MacOS/Driveway", bundleOwnerUID: 0, bundleWritableByNonRoot: false, hasHardenedRuntime: true, hasDangerousEntitlements: false))
    #expect(!CallerPolicy.accept(signingIdentifier: "app.driveway.Driveway", executablePath: "/tmp/Applications/Driveway.app/Contents/MacOS/Driveway", bundleOwnerUID: 0, bundleWritableByNonRoot: false, hasHardenedRuntime: true, hasDangerousEntitlements: false))
}

@Test func bundleWritability() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("DrivewayBundle-\(UUID().uuidString).app")
    defer { try? fm.removeItem(at: root) }
    let agent = root.appendingPathComponent("Contents/Library/LoginItems/DrivewayAgent.app/Contents/MacOS")
    try fm.createDirectory(at: agent, withIntermediateDirectories: true)
    try Data("x".utf8).write(to: agent.appendingPathComponent("DrivewayAgent"))
    // Owned by the user running the tests, not root.
    #expect(CallerPolicy.bundleIsWritableByNonRoot(at: root))
    // A path that doesn't exist fails closed.
    #expect(CallerPolicy.bundleIsWritableByNonRoot(at: root.appendingPathComponent("missing.app")))
}

@Test func bundleWritabilityChecksEveryItem() {
    // Root-owned, not group- or other-writable: fine. Any other owner, or a g+w / o+w bit, is not.
    #expect(!CallerPolicy.isWritableByNonRoot(owner: 0, mode: 0o40755))
    #expect(!CallerPolicy.isWritableByNonRoot(owner: 0, mode: 0o100644))
    #expect(CallerPolicy.isWritableByNonRoot(owner: 501, mode: 0o40755))
    #expect(CallerPolicy.isWritableByNonRoot(owner: 0, mode: 0o40775))
    #expect(CallerPolicy.isWritableByNonRoot(owner: 0, mode: 0o100666))
}

@Test func callerPolicyRequiresHardenedRuntime() {
    // Ad-hoc signed without the hardened runtime: DYLD_INSERT_LIBRARIES works on it.
    #expect(!CallerPolicy.accept(signingIdentifier: "app.driveway.Driveway", executablePath: appPath, bundleOwnerUID: 0, bundleWritableByNonRoot: false, hasHardenedRuntime: false, hasDangerousEntitlements: false))
    #expect(!CallerPolicy.accept(signingIdentifier: "app.driveway.agent", executablePath: agentPath, bundleOwnerUID: 0, bundleWritableByNonRoot: false, hasHardenedRuntime: false, hasDangerousEntitlements: false))
}

@Test func callerPolicyRejectsDangerousEntitlements() {
    #expect(!CallerPolicy.accept(signingIdentifier: "app.driveway.Driveway", executablePath: appPath, bundleOwnerUID: 0, bundleWritableByNonRoot: false, hasHardenedRuntime: true, hasDangerousEntitlements: true))
    for key in CallerPolicy.dangerousEntitlements {
        #expect(CallerPolicy.hasDangerousEntitlements([key: true]))
        #expect(CallerPolicy.hasDangerousEntitlements([key: "yes"]))
        #expect(!CallerPolicy.hasDangerousEntitlements([key: false]))
    }
    #expect(!CallerPolicy.hasDangerousEntitlements(nil))
    #expect(!CallerPolicy.hasDangerousEntitlements(["com.apple.security.app-sandbox": true]))
}

@Test func bundleWalkReachesTheNestedAgent() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("DrivewayBundle-\(UUID().uuidString).app")
    defer { try? fm.removeItem(at: root) }
    let macOS = root.appendingPathComponent("Contents/Library/LoginItems/DrivewayAgent.app/Contents/MacOS")
    try fm.createDirectory(at: macOS, withIntermediateDirectories: true)
    try Data("x".utf8).write(to: macOS.appendingPathComponent("DrivewayAgent"))
    try Data("x".utf8).write(to: root.appendingPathComponent("Contents/Info.plist"))

    func rootOwned(writableSuffix: String?) -> (String) -> (uid: UInt32, mode: UInt16)? {
        { path in
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDirectory) else { return nil }
            if let writableSuffix, path.hasSuffix(writableSuffix) { return (0, 0o100666) }
            return (0, isDirectory.boolValue ? 0o40755 : 0o100644)
        }
    }
    // Everything root-owned and closed: not writable.
    #expect(!CallerPolicy.bundleIsWritableByNonRoot(at: root, stat: rootOwned(writableSuffix: nil)))
    // Only the nested agent's executable is world-writable: found.
    #expect(CallerPolicy.bundleIsWritableByNonRoot(at: root, stat: rootOwned(writableSuffix: "MacOS/DrivewayAgent")))
}

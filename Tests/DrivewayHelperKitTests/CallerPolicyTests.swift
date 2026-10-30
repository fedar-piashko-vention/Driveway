import DrivewayHelperKit
import Foundation
import Testing

private let appPath = "/Applications/Driveway.app/Contents/MacOS/Driveway"
private let agentPath = "/Applications/Driveway.app/Contents/Library/LoginItems/DrivewayAgent.app/Contents/MacOS/DrivewayAgent"

@Test func callerPolicy() {
    let ok = CallerPolicy.accept(signingIdentifier: "app.driveway.Driveway", executablePath: appPath, bundleOwnerUID: 0, bundleWritableByNonRoot: false)
    #expect(ok)
    #expect(CallerPolicy.accept(signingIdentifier: "app.driveway.agent", executablePath: agentPath, bundleOwnerUID: 0, bundleWritableByNonRoot: false))
    #expect(!CallerPolicy.accept(signingIdentifier: "app.driveway.Driveway", executablePath: "/Users/x/Driveway.app/Contents/MacOS/Driveway", bundleOwnerUID: 0, bundleWritableByNonRoot: false))
    #expect(!CallerPolicy.accept(signingIdentifier: "app.driveway.Driveway", executablePath: appPath, bundleOwnerUID: 501, bundleWritableByNonRoot: false))
    #expect(!CallerPolicy.accept(signingIdentifier: "evil", executablePath: appPath, bundleOwnerUID: 0, bundleWritableByNonRoot: false))
}

@Test func callerPolicyRejectsWeakerCases() {
    // A bundle anyone but root can write to.
    #expect(!CallerPolicy.accept(signingIdentifier: "app.driveway.Driveway", executablePath: appPath, bundleOwnerUID: 0, bundleWritableByNonRoot: true))
    // No signing identifier.
    #expect(!CallerPolicy.accept(signingIdentifier: nil, executablePath: appPath, bundleOwnerUID: 0, bundleWritableByNonRoot: false))
    // Identifier and path must belong together.
    #expect(!CallerPolicy.accept(signingIdentifier: "app.driveway.agent", executablePath: appPath, bundleOwnerUID: 0, bundleWritableByNonRoot: false))
    #expect(!CallerPolicy.accept(signingIdentifier: "app.driveway.Driveway", executablePath: agentPath, bundleOwnerUID: 0, bundleWritableByNonRoot: false))
    // Paths that only look right.
    #expect(!CallerPolicy.accept(signingIdentifier: "app.driveway.Driveway", executablePath: "/Applications/Driveway.app/Contents/MacOS/../MacOS/Driveway", bundleOwnerUID: 0, bundleWritableByNonRoot: false))
    #expect(!CallerPolicy.accept(signingIdentifier: "app.driveway.Driveway", executablePath: "/tmp/Applications/Driveway.app/Contents/MacOS/Driveway", bundleOwnerUID: 0, bundleWritableByNonRoot: false))
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

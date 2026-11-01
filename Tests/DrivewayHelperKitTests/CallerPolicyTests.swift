import DrivewayHelperKit
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

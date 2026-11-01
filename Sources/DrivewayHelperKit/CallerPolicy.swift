/// Decides whether an XPC peer may talk to the root helper. The app is only ad-hoc signed, so the
/// signing identifier alone proves little. It must also run from its fixed install location, inside a
/// bundle owned by root that no other user can modify.
public enum CallerPolicy {
    /// Signing identifier -> the only executable path allowed to carry it.
    static let allowed: [String: String] = [
        "app.driveway.Driveway": "/Applications/Driveway.app/Contents/MacOS/Driveway",
        "app.driveway.agent":
            "/Applications/Driveway.app/Contents/Library/LoginItems/DrivewayAgent.app/Contents/MacOS/DrivewayAgent",
    ]

    /// `bundleOwnerUID` and `bundleWritableByNonRoot` describe `/Applications/Driveway.app`.
    /// The path is compared exactly, so "..", symlink-style detours and other prefixes are refused.
    public static func accept(
        signingIdentifier: String?, executablePath: String, bundleOwnerUID: UInt32, bundleWritableByNonRoot: Bool
    ) -> Bool {
        guard let id = signingIdentifier, let expected = allowed[id] else { return false }
        return executablePath == expected && bundleOwnerUID == 0 && !bundleWritableByNonRoot
    }
}

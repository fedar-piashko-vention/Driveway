/// User-facing strings. No copy here may suggest lowering macOS security.
public enum Copy {
    public static let unlock = "Unlock"
    public static let unlockEverything = "Unlock everything"
    public static let needsApproval = "Needs approval"
    public static let openSettings = "Open Settings"
    public static let notAvailableOnThisMac = "Not available on this Mac yet"
    public static let noBackendReason =
        "macFUSE can't mount drives on this macOS version with your Mac's security settings. Driveway checks again after each macOS or macFUSE update."

    public static func featuresReady(_ n: Int) -> String { "\(n) of 4 features ready" }
}

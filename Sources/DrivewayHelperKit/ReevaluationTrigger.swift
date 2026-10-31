import DrivewayCore

/// Decides when the helper runs the plug-in decision again for drives it doesn't hold (`reevaluateDrives`): when
/// someone logs in (or another user takes the console), when NTFS writing or ext drives become ready, and when the
/// helper gets the Full Disk Access it was known to lack.
public struct ReevaluationTrigger: Sendable {
    private var user: UInt32?
    private var ready: Set<Feature>
    /// The last definite answer about Full Disk Access; an unknown one changes nothing.
    private var fullDiskAccess: Bool?

    /// The features that decide whether Driveway mounts a drive.
    static let mountFeatures: [Feature] = [.writeNTFS, .extDrives]

    public init(user: ConsoleUser?, features: [Feature: FeatureState], fullDiskAccess: Bool? = nil) {
        self.user = HelperService.loggedIn(user)?.uid
        self.ready = Self.readyMountFeatures(features)
        self.fullDiskAccess = fullDiskAccess
    }

    /// Records the new state; true when a drive could now be mounted that couldn't before.
    public mutating func update(
        user newUser: ConsoleUser?, features: [Feature: FeatureState], fullDiskAccess access: Bool? = nil
    ) -> Bool {
        let uid = HelperService.loggedIn(newUser)?.uid
        let nowReady = Self.readyMountFeatures(features)
        let granted = access == true && fullDiskAccess == false
        defer {
            user = uid
            ready = nowReady
            if let access { fullDiskAccess = access }
        }
        guard uid != nil else { return false }
        return uid != user || !nowReady.subtracting(ready).isEmpty || granted
    }

    private static func readyMountFeatures(_ features: [Feature: FeatureState]) -> Set<Feature> {
        Set(mountFeatures.filter { features[$0] == .ready })
    }
}

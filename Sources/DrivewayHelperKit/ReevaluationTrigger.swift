import DrivewayCore

/// Decides when the helper runs the plug-in decision again for drives it doesn't hold (`reevaluateDrives`): when
/// someone logs in (or another user takes the console), and when NTFS writing or ext drives become ready.
public struct ReevaluationTrigger: Sendable {
    private var user: UInt32?
    private var ready: Set<Feature>

    /// The features that decide whether Driveway mounts a drive.
    static let mountFeatures: [Feature] = [.writeNTFS, .extDrives]

    public init(user: ConsoleUser?, features: [Feature: FeatureState]) {
        self.user = HelperService.loggedIn(user)?.uid
        self.ready = Self.readyMountFeatures(features)
    }

    /// Records the new state; true when a drive could now be mounted that couldn't before.
    public mutating func update(user newUser: ConsoleUser?, features: [Feature: FeatureState]) -> Bool {
        let uid = HelperService.loggedIn(newUser)?.uid
        let nowReady = Self.readyMountFeatures(features)
        defer {
            user = uid
            ready = nowReady
        }
        guard uid != nil else { return false }
        return uid != user || !nowReady.subtracting(ready).isEmpty
    }

    private static func readyMountFeatures(_ features: [Feature: FeatureState]) -> Set<Feature> {
        Set(mountFeatures.filter { features[$0] == .ready })
    }
}

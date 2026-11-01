import Testing
import Foundation
@testable import DrivewayCore

struct MountPolicyTests {
    let ready: [Feature: FeatureState] = [
        .readNTFS: .ready, .writeNTFS: .ready, .repairNTFS: .ready, .extDrives: .ready,
    ]
    let user = ConsoleUser(uid: 501, gid: 20)

    func action(
        _ fs: FilesystemKind, by owner: MountOwner = .macOS, key: String = "KEY",
        settings: DrivewaySettings = DrivewaySettings(), features: [Feature: FeatureState]? = nil,
        user: ConsoleUser?? = nil
    ) -> MountAction {
        autoMountAction(
            filesystem: fs, mountedBy: owner, settingsKey: key, settings: settings,
            features: features ?? ready, consoleUser: user ?? self.user)
    }

    // MARK: Policy

    @Test func ntfsMountsReadWriteByDefault() {
        #expect(action(.ntfs) == .mountNTFSReadWrite)
    }

    @Test func mountedByDrivewayMacOSOrNoneDoesNotChangeTheDecision() {
        for owner in [MountOwner.driveway, .macOS, .none] {
            #expect(action(.ntfs, by: owner) == .mountNTFSReadWrite)
            #expect(action(.ext4, by: owner) == .mountExtReadOnly)
            #expect(action(.exfat, by: owner) == .leaveToMacOS)
        }
    }

    @Test func otherDriverMeansBackOff() {
        #expect(action(.ntfs, by: .otherDriver("Tuxera NTFS")) == .backOff(driver: "Tuxera NTFS"))
        #expect(action(.ext4, by: .otherDriver("Paragon extFS")) == .backOff(driver: "Paragon extFS"))
    }

    @Test func otherDriverWinsEvenWithNoConsoleUser() {
        #expect(action(.ntfs, by: .otherDriver("Tuxera NTFS"), user: .some(nil)) == .backOff(driver: "Tuxera NTFS"))
    }

    @Test func autoMountOffLeavesToMacOS() {
        var settings = DrivewaySettings()
        settings.autoMountNTFS = false
        #expect(action(.ntfs, settings: settings) == .leaveToMacOS)
    }

    @Test func perDriveReadOnlyLeavesToMacOS() {
        var settings = DrivewaySettings()
        settings.alwaysReadOnly = ["KEY"]
        #expect(action(.ntfs, key: "KEY", settings: settings) == .leaveToMacOS)
        // A different drive is unaffected.
        #expect(action(.ntfs, key: "OTHER", settings: settings) == .mountNTFSReadWrite)
    }

    @Test func writeFeatureNotReadyLeavesToMacOS() {
        var notAvailable = ready
        notAvailable[.writeNTFS] = .notAvailableYet
        #expect(action(.ntfs, features: notAvailable) == .leaveToMacOS)

        var locked = ready
        locked[.writeNTFS] = .locked(missing: [.ntfs3g])
        #expect(action(.ntfs, features: locked) == .leaveToMacOS)

        var missing = ready
        missing[.writeNTFS] = nil
        #expect(action(.ntfs, features: missing) == .leaveToMacOS)
    }

    @Test func extMountsReadOnlyWhenReady() {
        #expect(action(.ext4) == .mountExtReadOnly)

        var locked = ready
        locked[.extDrives] = .locked(missing: [.ext4fuse])
        #expect(action(.ext4, features: locked) == .leaveToMacOS)
    }

    @Test func ext2AndExt3AlsoMountReadOnly() {
        #expect(action(.ext2) == .mountExtReadOnly)
        #expect(action(.ext3) == .mountExtReadOnly)
    }

    @Test func extIgnoresNTFSSettings() {
        var settings = DrivewaySettings()
        settings.autoMountNTFS = false
        settings.alwaysReadOnly = ["KEY"]
        #expect(action(.ext4, key: "KEY", settings: settings) == .mountExtReadOnly)
    }

    @Test func fatAndExfatAreLeftToMacOS() {
        #expect(action(.exfat) == .leaveToMacOS)
        #expect(action(.fat32) == .leaveToMacOS)
    }

    @Test func noConsoleUserLeavesToMacOS() {
        #expect(action(.ntfs, user: .some(nil)) == .leaveToMacOS)
        #expect(action(.ext4, user: .some(nil)) == .leaveToMacOS)
    }

    // MARK: Read-only fallback

    @Test func fallbacks() {
        #expect(readOnlyFallback(after: .mounted) == (health: .clean, reason: nil))
        #expect(readOnlyFallback(after: .dirty) == (health: .dirty, reason: nil))
        #expect(readOnlyFallback(after: .hibernated) == (health: .hibernated, reason: nil))
        #expect(
            readOnlyFallback(after: .notNTFS)
                == (health: .unknown, reason: "ntfs-3g says this isn't an NTFS volume."))
        #expect(
            readOnlyFallback(after: .corrupt)
                == (health: .unknown, reason: "ntfs-3g says this NTFS volume is damaged. Run chkdsk /f on Windows."))
        #expect(readOnlyFallback(after: .failed("boom")) == (health: .unknown, reason: "boom"))
    }

    // MARK: Settings

    @Test func emptyJSONDecodesToDefaults() throws {
        let s = try JSONDecoder().decode(DrivewaySettings.self, from: Data("{}".utf8))
        #expect(s == DrivewaySettings())
        #expect(s.autoMountNTFS == true)
        #expect(s.alwaysReadOnly.isEmpty)
        #expect(s.allowDiskImagesForTesting == false)
        #expect(s.fskitFailedOnOSBuild == nil)
    }

    @Test func jsonWithoutFskitFieldDecodes() throws {
        let json = #"{"autoMountNTFS":false,"alwaysReadOnly":["A"],"allowDiskImagesForTesting":true}"#
        let s = try JSONDecoder().decode(DrivewaySettings.self, from: Data(json.utf8))
        #expect(s.autoMountNTFS == false)
        #expect(s.alwaysReadOnly == ["A"])
        #expect(s.allowDiskImagesForTesting == true)
        #expect(s.fskitFailedOnOSBuild == nil)
    }

    @Test func settingsRoundTrip() throws {
        let s = DrivewaySettings(
            autoMountNTFS: false, alwaysReadOnly: ["A", "B"], allowDiskImagesForTesting: true,
            fskitFailedOnOSBuild: "24G123")
        let data = try JSONEncoder().encode(s)
        #expect(try JSONDecoder().decode(DrivewaySettings.self, from: data) == s)
    }
}

struct LeaveReasonTests {
    @Test func leaveReasonsFollowTheMountRules() {
        let user = ConsoleUser(uid: 501, gid: 20)
        let ready: [Feature: FeatureState] = [.readNTFS: .ready, .writeNTFS: .ready, .repairNTFS: .ready, .extDrives: .ready]
        func reason(
            _ fs: FilesystemKind, _ settings: DrivewaySettings = DrivewaySettings(),
            _ features: [Feature: FeatureState]? = nil, user u: ConsoleUser? = user
        ) -> LeaveReason? {
            autoMountLeaveReason(
                filesystem: fs, settingsKey: "K", settings: settings, features: features ?? ready, consoleUser: u)
        }
        #expect(reason(.ntfs) == nil)
        #expect(reason(.ext4) == nil)
        #expect(reason(.ntfs, user: nil) == .nobodyLoggedIn)
        #expect(reason(.exfat) == .notDrivewayFilesystem(.exfat))
        #expect(reason(.ntfs, DrivewaySettings(autoMountNTFS: false)) == .autoMountOff)
        #expect(reason(.ntfs, DrivewaySettings(alwaysReadOnly: ["K"])) == .alwaysReadOnly)
        var locked = ready
        locked[.writeNTFS] = .locked(missing: [.fullDiskAccess])
        #expect(reason(.ntfs, DrivewaySettings(), locked) == .featureNotReady(.writeNTFS, .locked(missing: [.fullDiskAccess])))
        locked[.extDrives] = .notAvailableYet
        #expect(reason(.ext4, DrivewaySettings(), locked) == .featureNotReady(.extDrives, .notAvailableYet))

        #expect(LeaveReason.autoMountOff.description == "auto-mount is off")
        #expect(LeaveReason.nobodyLoggedIn.description == "nobody is logged in")
        #expect(LeaveReason.alwaysReadOnly.description == "the drive is set to always mount read-only")
        #expect(
            LeaveReason.featureNotReady(.writeNTFS, .locked(missing: [.fullDiskAccess])).description
                == "writeNTFS is not ready (locked: fullDiskAccess)")
    }

    @Test func autoMountActionAgreesWithTheLeaveReason() {
        let user = ConsoleUser(uid: 501, gid: 20)
        let ready: [Feature: FeatureState] = [.readNTFS: .ready, .writeNTFS: .ready, .repairNTFS: .ready, .extDrives: .ready]
        for fs in FilesystemKind.allCases {
            for settings in [DrivewaySettings(), DrivewaySettings(autoMountNTFS: false), DrivewaySettings(alwaysReadOnly: ["K"])] {
                for u in [user, nil] {
                    let action = autoMountAction(
                        filesystem: fs, mountedBy: .none, settingsKey: "K", settings: settings, features: ready, consoleUser: u)
                    let reason = autoMountLeaveReason(
                        filesystem: fs, settingsKey: "K", settings: settings, features: ready, consoleUser: u)
                    #expect((action == .leaveToMacOS) == (reason != nil), "\(fs) \(settings) \(String(describing: u))")
                }
            }
        }
    }
}

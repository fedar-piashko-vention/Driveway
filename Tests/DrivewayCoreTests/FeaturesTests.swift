import Testing
import Foundation
@testable import DrivewayCore

struct FeaturesTests {
    let full = ToolInventory(
        hasHomebrew: true, macFUSEVersion: SemanticVersion("5.4.0"), backend: .ready(.kernel), hasNTFS3G: true,
        hasExt4fuse: true, hasE2fsprogs: true, helperVersion: "1.0.0", appVersion: "1.0.0", conflictingDrivers: [])

    @Test func everythingInstalledIsFourOfFour() {
        #expect(readyCount(featureStates(full, ntfsWriteSupported: true, macOSMajor: 15)) == 4)
    }

    @Test func readNTFSAlwaysReady() {
        let empty = ToolInventory(
            hasHomebrew: false, macFUSEVersion: nil, backend: .unavailable, hasNTFS3G: false,
            hasExt4fuse: false, hasE2fsprogs: false, helperVersion: nil, appVersion: "1.0.0", conflictingDrivers: [])
        #expect(featureStates(empty, macOSMajor: 15)[.readNTFS] == .ready)
    }

    @Test func writeNTFSRequirementsInOrder() {
        var inv = full
        inv.hasHomebrew = false; inv.hasNTFS3G = false; inv.macFUSEVersion = nil; inv.helperVersion = nil
        #expect(featureStates(inv, ntfsWriteSupported: true, macOSMajor: 15)[.writeNTFS] == .locked(missing: [.homebrew, .macFUSE, .ntfs3g, .helper]))
    }

    @Test func oldMacFUSENeedsUpdate() {
        var inv = full
        inv.macFUSEVersion = SemanticVersion("5.3.2")
        let installed = SemanticVersion("5.3.2")!
        #expect(featureStates(inv, ntfsWriteSupported: true, macOSMajor: 15)[.writeNTFS] == .locked(missing: [.macFUSEUpdate(installed: installed)]))
        #expect(featureStates(inv, ntfsWriteSupported: true, macOSMajor: 15)[.extDrives] == .locked(missing: [.macFUSEUpdate(installed: installed)]))
    }

    @Test func macFUSEVersionsCompareNumerically() {
        for v in ["5.4.0", "5.4.1", "5.10.0", "6.0.0"] {
            var inv = full
            inv.macFUSEVersion = SemanticVersion(v)
            #expect(featureStates(inv, ntfsWriteSupported: true, macOSMajor: 15)[.writeNTFS] == .ready, "macFUSE \(v) should be ready")
        }
        var old = full
        old.macFUSEVersion = SemanticVersion("5.3.2")
        #expect(featureStates(old, ntfsWriteSupported: true, macOSMajor: 15)[.writeNTFS] == .locked(missing: [.macFUSEUpdate(installed: SemanticVersion("5.3.2")!)]))
    }

    @Test func unapprovedMacFUSE() {
        var inv = full
        inv.backend = .needsApproval(.fskit)
        #expect(featureStates(inv, ntfsWriteSupported: true, macOSMajor: 15)[.writeNTFS] == .locked(missing: [.macFUSEApproval(.fskit)]))
        #expect(featureStates(inv, ntfsWriteSupported: true, macOSMajor: 15)[.extDrives] == .locked(missing: [.macFUSEApproval(.fskit)]))
        inv.backend = .needsApproval(.kernel)
        #expect(featureStates(inv, ntfsWriteSupported: true, macOSMajor: 15)[.writeNTFS] == .locked(missing: [.macFUSEApproval(.kernel)]))
        #expect(featureStates(inv, ntfsWriteSupported: true, macOSMajor: 15)[.extDrives] == .locked(missing: [.macFUSEApproval(.kernel)]))
    }

    @Test func noUsableBackendMeansNotAvailableYet() {
        var inv = full
        inv.backend = .unavailable
        let states = featureStates(inv, ntfsWriteSupported: true, macOSMajor: 15)
        #expect(states[.writeNTFS] == .notAvailableYet)
        #expect(states[.extDrives] == .notAvailableYet)
    }

    @Test func notAvailableYetWinsOverOtherMissingItemsOnceMacFUSEIsCurrent() {
        var inv = full
        inv.backend = .unavailable; inv.hasNTFS3G = false; inv.hasExt4fuse = false; inv.helperVersion = nil
        let states = featureStates(inv, ntfsWriteSupported: true, macOSMajor: 15)
        #expect(states[.writeNTFS] == .notAvailableYet)
        #expect(states[.extDrives] == .notAvailableYet)
        #expect(states[.repairNTFS] == .locked(missing: [.ntfs3g, .helper]))
    }

    @Test func missingMacFUSEIgnoresUnavailableBackend() {
        var inv = full
        inv.macFUSEVersion = nil
        inv.backend = .unavailable
        #expect(featureStates(inv, ntfsWriteSupported: true, macOSMajor: 15)[.writeNTFS] == .locked(missing: [.macFUSE]))
        #expect(featureStates(inv, ntfsWriteSupported: true, macOSMajor: 15)[.extDrives] == .locked(missing: [.macFUSE]))
    }

    @Test func outdatedMacFUSEIgnoresBackendApprovalAndUnavailable() {
        var inv = full
        inv.macFUSEVersion = SemanticVersion("5.3.2")
        let installed = SemanticVersion("5.3.2")!
        inv.backend = .needsApproval(.kernel)
        #expect(featureStates(inv, ntfsWriteSupported: true, macOSMajor: 15)[.writeNTFS] == .locked(missing: [.macFUSEUpdate(installed: installed)]))
        inv.backend = .unavailable
        #expect(featureStates(inv, ntfsWriteSupported: true, macOSMajor: 15)[.writeNTFS] == .locked(missing: [.macFUSEUpdate(installed: installed)]))
    }

    @Test func readyCountIsTwoWhenBackendUnavailableAndEverythingElseInstalled() {
        var inv = full
        inv.backend = .unavailable
        let states = featureStates(inv, ntfsWriteSupported: true, macOSMajor: 15)
        #expect(states[.readNTFS] == .ready)
        #expect(states[.repairNTFS] == .ready)
        #expect(readyCount(states) == 2)
    }

    @Test func backendPolicyTable() {
        #expect(BackendPolicy.availability(kextsAllowed: true, kextApproved: true, fskitEnabled: true, fskitFailedOnThisOS: false) == .ready(.kernel))
        #expect(BackendPolicy.availability(kextsAllowed: true, kextApproved: false, fskitEnabled: true, fskitFailedOnThisOS: true) == .needsApproval(.kernel))
        #expect(BackendPolicy.availability(kextsAllowed: false, kextApproved: false, fskitEnabled: true, fskitFailedOnThisOS: false) == .ready(.fskit))
        #expect(BackendPolicy.availability(kextsAllowed: false, kextApproved: false, fskitEnabled: false, fskitFailedOnThisOS: false) == .needsApproval(.fskit))
        #expect(BackendPolicy.availability(kextsAllowed: false, kextApproved: true, fskitEnabled: true, fskitFailedOnThisOS: true) == .unavailable)
    }

    @Test func noGoSpikeMeansNotAvailableYet() {
        let states = featureStates(full, ntfsWriteSupported: false, macOSMajor: 15)
        #expect(states[.writeNTFS] == .notAvailableYet)
        #expect(states[.extDrives] == .ready)
        #expect(readyCount(states) == 3)
    }

    @Test func staleHelperIsNotReady() {
        var inv = full
        inv.helperVersion = "0.9.0"
        #expect(featureStates(inv, ntfsWriteSupported: true, macOSMajor: 15)[.writeNTFS] == .locked(missing: [.helperUpdate]))
        #expect(featureStates(inv, ntfsWriteSupported: true, macOSMajor: 15)[.repairNTFS] == .locked(missing: [.helperUpdate]))
    }

    @Test func homebrewOnlyListedWhenABrewToolIsMissing() {
        var inv = full
        inv.hasHomebrew = false
        // All Homebrew-installed tools present: Homebrew itself is not needed.
        #expect(readyCount(featureStates(inv, ntfsWriteSupported: true, macOSMajor: 15)) == 4)
        // A missing helper alone does not need Homebrew.
        inv.helperVersion = nil
        #expect(featureStates(inv, ntfsWriteSupported: true, macOSMajor: 15)[.writeNTFS] == .locked(missing: [.helper]))
        // A missing brew tool does, but only for features that use it.
        inv.hasExt4fuse = false
        #expect(featureStates(inv, ntfsWriteSupported: true, macOSMajor: 15)[.extDrives] == .locked(missing: [.homebrew, .ext4fuse, .helper]))
        #expect(featureStates(inv, ntfsWriteSupported: true, macOSMajor: 15)[.writeNTFS] == .locked(missing: [.helper]))
    }

    @Test func homebrewListedForMissingOrOutdatedMacFUSE() {
        var inv = full
        inv.hasHomebrew = false
        inv.macFUSEVersion = SemanticVersion("5.3.2")
        #expect(featureStates(inv, ntfsWriteSupported: true, macOSMajor: 15)[.writeNTFS] == .locked(missing: [.homebrew, .macFUSEUpdate(installed: SemanticVersion("5.3.2")!)]))
    }

    @Test func detectsConflictingDrivers() {
        #expect(ConflictingDrivers.detect(filesystemBundles: ["macfuse.fs", "tuxera_ntfs.fs", "ufsd_NTFS.fs", "exfat.fs"]) == ["Tuxera NTFS", "Paragon NTFS"])
        #expect(ConflictingDrivers.detect(filesystemBundles: ["ufsd_ExtFS.fs"]) == ["Paragon extFS"])
        #expect(ConflictingDrivers.detect(filesystemBundles: ["macfuse.fs"]).isEmpty)
        #expect(ConflictingDrivers.driverName(forDAVolumeKind: "tuxera_ntfs") == "Tuxera NTFS")
        #expect(ConflictingDrivers.driverName(forDAVolumeKind: "ufsd_NTFS") == "Paragon NTFS")
        #expect(ConflictingDrivers.driverName(forDAVolumeKind: "ufsd_ExtFS") == "Paragon extFS")
        #expect(ConflictingDrivers.driverName(forDAVolumeKind: "ntfs") == nil)
        #expect(ConflictingDrivers.driverName(forDAVolumeKind: nil) == nil)
    }

    @Test func installSteps() {
        #expect(InstallStep.for(.homebrew) == .openURL(URL(string: "https://brew.sh")!))
        #expect(InstallStep.for(.ntfs3g) == .runBrew(["install", "gromgit/fuse/ntfs-3g-mac"]))
        #expect(InstallStep.for(.ext4fuse) == .runBrew(["install", "gromgit/fuse/ext4fuse-mac"]))
        #expect(InstallStep.for(.e2fsprogs) == .runBrew(["install", "e2fsprogs"]))
        #expect(InstallStep.for(.macFUSE) == .runInTerminal("/opt/homebrew/bin/brew install --cask macfuse"))
        #expect(InstallStep.for(.macFUSEUpdate(installed: SemanticVersion("5.3.0")!)) == .runInTerminal("/opt/homebrew/bin/brew upgrade --cask macfuse"))
        #expect(InstallStep.for(.macFUSEApproval(.fskit)) == .openSettings(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!))
        #expect(InstallStep.for(.macFUSEApproval(.kernel)) == .openSettings(URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension")!))
        #expect(InstallStep.for(.helper) == .installHelper && InstallStep.for(.helperUpdate) == .installHelper)
    }

    @Test func setupShowsOnFirstLaunchOrRegression() {
        #expect(SetupPolicy.shouldShowSetup(previouslyReady: nil, nowReady: Set(Feature.allCases)))
        #expect(SetupPolicy.shouldShowSetup(previouslyReady: [.readNTFS, .writeNTFS], nowReady: [.readNTFS]))
        #expect(!SetupPolicy.shouldShowSetup(previouslyReady: [.readNTFS], nowReady: [.readNTFS, .writeNTFS]))
    }

    @Test func setupPolicyEdgeCases() {
        #expect(!SetupPolicy.shouldShowSetup(previouslyReady: [.readNTFS, .writeNTFS], nowReady: [.readNTFS, .writeNTFS]))
        #expect(!SetupPolicy.shouldShowSetup(previouslyReady: [], nowReady: []))
        #expect(!SetupPolicy.shouldShowSetup(previouslyReady: [], nowReady: [.readNTFS]))
        // A feature that was ready and is now notAvailableYet (so no longer ready) is a regression.
        var inv = full
        let before = featureStates(inv, ntfsWriteSupported: true, macOSMajor: 15)
        inv.backend = .unavailable
        let after = featureStates(inv, ntfsWriteSupported: true, macOSMajor: 15)
        #expect(after[.writeNTFS] == .notAvailableYet)
        func ready(_ s: [Feature: FeatureState]) -> Set<Feature> { Set(s.filter { $0.value == .ready }.keys) }
        #expect(SetupPolicy.shouldShowSetup(previouslyReady: ready(before), nowReady: ready(after)))
    }

    @Test func copyStrings() {
        #expect(Copy.featuresReady(3) == "3 of 4 features ready")
        #expect(Copy.unlock == "Unlock")
        #expect(Copy.unlockEverything == "Unlock everything")
        #expect(Copy.needsApproval == "Needs approval")
        #expect(Copy.openSettings == "Open Settings")
        #expect(Copy.notAvailableOnThisMac == "Not available on this Mac yet")
        #expect(Copy.noBackendReason == "macFUSE can't mount drives on this macOS version with your Mac's security settings. Driveway checks again after each macOS or macFUSE update.")
    }
}

/// macFUSE 5.5.0 works around FSKit returning wrong data on macOS 26 and 27, so those need it; macOS 15 keeps 5.4.0.
struct MacFUSEMinimumTests {
    let inv = ToolInventory(
        hasHomebrew: true, macFUSEVersion: SemanticVersion("5.4.1"), backend: .ready(.fskit), hasNTFS3G: true,
        hasExt4fuse: true, hasE2fsprogs: true, helperVersion: "1.0.0", appVersion: "1.0.0", conflictingDrivers: [])

    @Test func minimumDependsOnMacOSVersion() {
        #expect(minimumMacFUSE(macOSMajor: 15) == SemanticVersion("5.4.0"))
        #expect(minimumMacFUSE(macOSMajor: 26) == SemanticVersion("5.5.0"))
        #expect(minimumMacFUSE(macOSMajor: 27) == SemanticVersion("5.5.0"))
    }

    @Test func macOS26NeedsMacFUSE55() {
        let installed = SemanticVersion("5.4.1")!
        for major in [26, 27] {
            let states = featureStates(inv, ntfsWriteSupported: true, macOSMajor: major)
            #expect(states[.writeNTFS] == .locked(missing: [.macFUSEUpdate(installed: installed)]))
            #expect(states[.extDrives] == .locked(missing: [.macFUSEUpdate(installed: installed)]))
        }
        var current = inv
        current.macFUSEVersion = SemanticVersion("5.5.0")
        #expect(featureStates(current, ntfsWriteSupported: true, macOSMajor: 26)[.writeNTFS] == .ready)
    }

    @Test func macOS15StillAccepts54() {
        #expect(featureStates(inv, ntfsWriteSupported: true, macOSMajor: 15)[.writeNTFS] == .ready)
    }

    @Test func labelsNameTheMinimumForThisMacOS() {
        let old = Requirement.macFUSEUpdate(installed: SemanticVersion("5.4.1")!)
        #expect(Copy.requirementLabel(.macFUSE, macOSMajor: 26) == "macFUSE 5.5 or later")
        #expect(Copy.requirementLabel(old, macOSMajor: 26) == "macFUSE 5.4.1 — needs update to 5.5 or later")
        #expect(Copy.requirementLabel(.macFUSE, macOSMajor: 15) == "macFUSE 5.4 or later")
    }
}

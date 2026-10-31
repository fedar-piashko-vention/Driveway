import Foundation
import Testing
@testable import DrivewayCore

private let kmutilLoaded = "com.apple.foo (1.0)\nio.macfuse.filesystems.macfuse.23 (5.5.0)\n"
private let pluginkitEnabled =
    "     io.macfuse.app.fsmodule.macfuse-local((null))\t6F1A2B3C-0000-4000-8000-000000000001\t2026-10-30 15:20:00 +0000\t/x.appex\n"
private let pluginkitDisabled = "-    io.macfuse.app.fsmodule.macfuse-local((null))\tX\n"

struct BackendWithoutHelperTests {
    @Test func loadedKextMeansKernel() {
        #expect(BackendPolicy.availabilityWithoutHelper(kmutilOutput: kmutilLoaded, pluginkitOutput: nil) == .ready(.kernel))
        // The kext wins over an enabled FSKit module.
        #expect(
            BackendPolicy.availabilityWithoutHelper(kmutilOutput: kmutilLoaded, pluginkitOutput: pluginkitEnabled)
                == .ready(.kernel))
    }

    @Test func approvedFSKitModuleMeansFSKit() {
        #expect(
            BackendPolicy.availabilityWithoutHelper(kmutilOutput: "com.apple.foo (1.0)\n", pluginkitOutput: pluginkitEnabled)
                == .ready(.fskit))
        #expect(BackendPolicy.availabilityWithoutHelper(kmutilOutput: nil, pluginkitOutput: pluginkitEnabled) == .ready(.fskit))
    }

    @Test func neitherSignalIsANonBlockingKernelPlaceholder() {
        #expect(BackendPolicy.availabilityWithoutHelper(kmutilOutput: nil, pluginkitOutput: nil) == .ready(.kernel))
        #expect(BackendPolicy.availabilityWithoutHelper(kmutilOutput: "", pluginkitOutput: pluginkitDisabled) == .ready(.kernel))
    }
}

struct TerminalScriptTests {
    @Test func doScriptInTerminal() {
        #expect(
            TerminalScript.osascriptArguments(command: "/opt/homebrew/bin/brew install --cask macfuse")
                == ["-e", #"tell application "Terminal" to do script "/opt/homebrew/bin/brew install --cask macfuse""#,
                    "-e", #"tell application "Terminal" to activate"#])
    }

    @Test func escapesQuotesAndBackslashes() {
        #expect(
            TerminalScript.osascriptArguments(command: #"echo "a\b""#)[1]
                == #"tell application "Terminal" to do script "echo \"a\\b\"""#)
    }

    @Test func recognisesACanceledAdministratorPrompt() {
        #expect(PrivilegedShellScript.isUserCanceled(stderr: "0:68: execution error: User canceled. (-128)"))
        #expect(!PrivilegedShellScript.isUserCanceled(stderr: "0:90: execution error: Usage: install-helper.sh (64)"))
        #expect(!PrivilegedShellScript.isUserCanceled(stderr: ""))
    }
}

struct SetupScreenTests {
    let empty = ToolInventory(
        hasHomebrew: false, macFUSEVersion: nil, backend: .ready(.kernel), hasNTFS3G: false,
        hasExt4fuse: false, hasE2fsprogs: false, helperVersion: nil, appVersion: "1.0.0", conflictingDrivers: [])
    let full = ToolInventory(
        hasHomebrew: true, macFUSEVersion: SemanticVersion("5.5.0"), backend: .ready(.kernel), hasNTFS3G: true,
        hasExt4fuse: true, hasE2fsprogs: true, helperVersion: "1.0.0", appVersion: "1.0.0", conflictingDrivers: [])

    @Test func groupsFollowFeatureOrderWithMockupTitles() {
        let groups = SetupScreen.groups(featureStates(empty, ntfsWriteSupported: true))
        #expect(groups.map(\.feature) == [.readNTFS, .writeNTFS, .repairNTFS, .extDrives])
        #expect(groups.map(\.title) == ["Read NTFS drives", "Write to NTFS drives", "Check & Repair NTFS", "ext drives (optional)"])
    }

    @Test func readNTFSIsBuiltIn() {
        let read = SetupScreen.groups(featureStates(empty, ntfsWriteSupported: true))[0]
        #expect(read.state == .ready)
        #expect(read.detail == "Built into macOS")
        #expect(read.items.isEmpty)
    }

    @Test func lockedGroupListsMissingRequirementsInUnlockOrder() {
        let write = SetupScreen.groups(featureStates(empty, ntfsWriteSupported: true))[1]
        #expect(write.items.map(\.requirement) == [.homebrew, .macFUSE, .ntfs3g, .helper])
        #expect(write.items.map(\.label) == ["Homebrew", "macFUSE 5.4 or later", "ntfs-3g", "Driveway helper"])
        #expect(write.items.allSatisfy { $0.symbol == "❌" })
    }

    @Test func approvalsAndUpdatesAreWarnings() {
        var inv = full
        inv.backend = .needsApproval(.kernel)
        inv.helperVersion = "0.9.0"
        let write = SetupScreen.groups(featureStates(inv, ntfsWriteSupported: true))[1]
        #expect(write.items.map(\.requirement) == [.macFUSEApproval(.kernel), .helperUpdate])
        #expect(write.items.map(\.symbol) == ["⚠️", "⚠️"])
        #expect(write.items[0].label == "macFUSE — needs approval in System Settings → Privacy & Security")
        #expect(write.items[1].label == "Driveway helper — needs update")

        inv.backend = .needsApproval(.fskit)
        inv.macFUSEVersion = SemanticVersion("5.5.0")
        #expect(
            SetupScreen.groups(featureStates(inv, ntfsWriteSupported: true))[1].items[0].label
                == "macFUSE — needs approval in System Settings → General → Login Items & Extensions")

        inv.macFUSEVersion = SemanticVersion("5.3.2")
        let old = SetupScreen.groups(featureStates(inv, ntfsWriteSupported: true))[1].items[0]
        #expect(old.label == "macFUSE 5.3.2 — needs update to 5.4 or later")
        #expect(old.symbol == "⚠️")
    }

    @Test func notAvailableYetShowsTheReasonInsteadOfItems() {
        var inv = full
        inv.backend = .unavailable
        let write = SetupScreen.groups(featureStates(inv, ntfsWriteSupported: true))[1]
        #expect(write.state == .notAvailableYet)
        #expect(write.items.isEmpty)
        #expect(write.detail == "\(Copy.notAvailableOnThisMac). \(Copy.noBackendReason)")
    }

    @Test func readyFeatures() {
        var inv = full
        inv.hasExt4fuse = false
        #expect(SetupScreen.readyFeatures(featureStates(inv, ntfsWriteSupported: true)) == [.readNTFS, .writeNTFS, .repairNTFS])
    }

    @Test func unlockOrderForOneFeatureIsItsRequirementOrder() {
        let states = featureStates(empty, ntfsWriteSupported: true)
        #expect(SetupScreen.unlockOrder(for: [.extDrives], in: states) == [.homebrew, .macFUSE, .ext4fuse, .e2fsprogs, .helper])
        #expect(SetupScreen.unlockOrder(for: [.readNTFS], in: states).isEmpty)
    }

    @Test func unlockEverythingDeduplicatesAndInstallsTheHelperLast() {
        let states = featureStates(empty, ntfsWriteSupported: true)
        #expect(
            SetupScreen.unlockOrder(for: Feature.allCases, in: states)
                == [.homebrew, .macFUSE, .ntfs3g, .ext4fuse, .e2fsprogs, .helper])
    }

    @Test func unlockSkipsFeaturesThatAreNotAvailableYet() {
        var inv = full
        inv.backend = .unavailable
        inv.hasNTFS3G = false
        let states = featureStates(inv, ntfsWriteSupported: true)
        #expect(SetupScreen.unlockOrder(for: Feature.allCases, in: states) == [.ntfs3g])
    }

    @Test func runNowStopsAfterAStepThatContinuesOutsideDriveway() {
        #expect(SetupScreen.runNow([.homebrew, .macFUSE, .ntfs3g, .helper]) == [.homebrew])
        #expect(SetupScreen.runNow([.macFUSE, .ntfs3g, .helper]) == [.macFUSE])
        #expect(SetupScreen.runNow([.macFUSEApproval(.kernel), .helper]) == [.macFUSEApproval(.kernel)])
        #expect(SetupScreen.runNow([.ntfs3g, .e2fsprogs, .helper]) == [.ntfs3g, .e2fsprogs, .helper])
        #expect(SetupScreen.runNow([]).isEmpty)
    }

    @Test func handoffSteps() {
        #expect(InstallStep.for(.homebrew).continuesOutsideDriveway)
        #expect(InstallStep.for(.macFUSE).continuesOutsideDriveway)
        #expect(InstallStep.for(.macFUSEApproval(.fskit)).continuesOutsideDriveway)
        #expect(!InstallStep.for(.ntfs3g).continuesOutsideDriveway)
        #expect(!InstallStep.for(.helper).continuesOutsideDriveway)
    }

    @Test func buttonSaysOpenSettingsWhenApprovalComesFirst() {
        #expect(SetupScreen.buttonTitle(for: [.macFUSEApproval(.kernel), .helper]) == Copy.openSettings)
        #expect(SetupScreen.buttonTitle(for: [.ntfs3g, .helper]) == Copy.unlock)
        #expect(SetupScreen.buttonTitle(for: []) == Copy.unlock)
    }

    @Test func handoffNotices() {
        #expect(Copy.afterHandoff(.homebrew) != nil)
        #expect(Copy.afterHandoff(.macFUSE) != nil)
        #expect(Copy.afterHandoff(.macFUSEUpdate(installed: SemanticVersion("5.3.0")!)) != nil)
        #expect(Copy.afterHandoff(.macFUSEApproval(.kernel))?.contains("Privacy & Security") == true)
        #expect(Copy.afterHandoff(.macFUSEApproval(.fskit))?.contains("File System Extensions") == true)
        #expect(Copy.afterHandoff(.ntfs3g) == nil)
        #expect(Copy.afterHandoff(.helper) == nil)
    }

    @Test func conflictRowsNameTheDriverWithUninstallGuidance() {
        #expect(
            Copy.conflictWarning(driver: "Tuxera NTFS")
                == "Tuxera NTFS is installed. Driveway leaves drives it mounts alone. Uninstall it to let Driveway mount NTFS drives.")
        #expect(
            Copy.conflictWarning(driver: "Paragon extFS")
                == "Paragon extFS is installed. Driveway leaves drives it mounts alone. Uninstall it to let Driveway mount ext drives.")
        #expect(ConflictingDrivers.supportURL(for: "Tuxera NTFS") == URL(string: "https://www.tuxera.com/support/"))
        #expect(ConflictingDrivers.supportURL(for: "Paragon NTFS") == URL(string: "https://www.paragon-software.com/support/"))
        #expect(ConflictingDrivers.supportURL(for: "Paragon extFS") == URL(string: "https://www.paragon-software.com/support/"))
        #expect(ConflictingDrivers.supportURL(for: "Other") == nil)
    }

    @Test func noSetupCopySuggestsLoweringSecurity() {
        var texts: [String] = [
            Copy.untrustedTapNote, Copy.moveToApplications, Copy.conflictWarning(driver: "Tuxera NTFS"),
            Copy.notAvailableOnThisMac, Copy.noBackendReason, Copy.needsFullDiskAccess(label: "BACKUP"),
            Copy.fullDiskAccessHint, Copy.fullDiskAccessSteps,
        ]
        let requirements: [Requirement] = [
            .homebrew, .macFUSE, .macFUSEUpdate(installed: SemanticVersion("5.3.0")!), .macFUSEApproval(.kernel),
            .macFUSEApproval(.fskit), .ntfs3g, .ext4fuse, .e2fsprogs, .helper, .helperUpdate, .fullDiskAccess,
        ]
        texts += requirements.map(Copy.requirementLabel)
        texts += requirements.compactMap(Copy.afterHandoff)
        var inv = full
        inv.backend = .unavailable
        texts += SetupScreen.groups(featureStates(inv, ntfsWriteSupported: true)).compactMap(\.detail)
        for text in texts {
            let lowered = text.lowercased()
            for banned in ["sip", "csrutil", "disable", "lower", "reduce", "recovery", "startup security"] {
                #expect(!lowered.contains(banned), "\"\(text)\" mentions \(banned)")
            }
        }
    }
}

struct LineSplitterTests {
    @Test func splitsAcrossChunks() {
        var splitter = LineSplitter()
        #expect(splitter.append(Data("==> Fetch".utf8)).isEmpty)
        #expect(splitter.append(Data("ing ntfs-3g\nPour".utf8)) == ["==> Fetching ntfs-3g"])
        #expect(splitter.append(Data("ing\r\n\nDone\r".utf8)) == ["Pouring", "Done"])
        #expect(splitter.finish() == nil)
    }

    @Test func finishReturnsTheUnterminatedTail() {
        var splitter = LineSplitter()
        #expect(splitter.append(Data("a\nDo you want to continue? [y/N] ".utf8)) == ["a"])
        // A prompt has no newline yet; the log shows it as the unfinished last line.
        #expect(splitter.tail == "Do you want to continue? [y/N] ")
        #expect(splitter.finish() == "Do you want to continue? [y/N] ")
        #expect(splitter.finish() == nil)
    }

    @Test func keepsMultibyteCharactersSplitBetweenChunks() {
        var splitter = LineSplitter()
        let bytes = Array("🍺 done\n".utf8)
        #expect(splitter.append(Data(bytes[0..<2])).isEmpty)
        #expect(splitter.append(Data(bytes[2...])) == ["🍺 done"])
    }
}

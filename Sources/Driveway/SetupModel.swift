import DrivewayCore
import Foundation
import Observation

/// The Setup scan and installs, shared by the Setup window, the Disk Manager and the app menu. Every scan updates
/// the Disk Manager's ready features, which the Format tab gates on.
@MainActor
@Observable
final class SetupModel {
    static let previouslyReadyKey = "previouslyReadyFeatures"

    private(set) var inventory: ToolInventory?
    private(set) var states: [Feature: FeatureState] = [:]
    /// An unlock or uninstall in progress.
    private(set) var isWorking = false
    /// What to do next after a step that continues outside Driveway.
    private(set) var notice: String?
    var errorMessage: String?
    /// The install log sheet, shown while brew steps run and until the user closes it.
    var logShown = false
    private(set) var log: [String] = []
    let installer: Installer

    @ObservationIgnored private let scanner: ToolInventoryScanner
    @ObservationIgnored private let diskManager: DiskManagerModel
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var rescanRequested = false
    @ObservationIgnored private var launchChecked = false

    init(client: HelperClient, diskManager: DiskManagerModel, installer: Installer = Installer()) {
        self.scanner = ToolInventoryScanner(client: client)
        self.diskManager = diskManager
        self.installer = installer
    }

    var hasScanned: Bool { inventory != nil }
    var groups: [SetupGroup] { SetupScreen.groups(states) }
    var readyCount: Int { DrivewayCore.readyCount(states) }
    var conflicts: [String] { inventory?.conflictingDrivers ?? [] }
    var canUnlockEverything: Bool { !isWorking && !SetupScreen.unlockOrder(for: Feature.allCases, in: states).isEmpty }

    func buttonTitle(for feature: Feature) -> String {
        SetupScreen.buttonTitle(for: SetupScreen.unlockOrder(for: [feature], in: states))
    }

    /// Scans now. A scan requested while one runs makes it run once more; every caller returns after that.
    func scan() async {
        if let scanTask {
            rescanRequested = true
            await scanTask.value
            return
        }
        let task = Task { [weak self] in
            var again = true
            while again, let self {
                self.rescanRequested = false
                await self.scanOnce()
                again = self.rescanRequested
            }
            // Cleared by the task itself, on the main actor, so no request can slip in after the last check.
            self?.scanTask = nil
        }
        scanTask = task
        await task.value
    }

    /// The app became active (the user may be back from Terminal or System Settings): scan unless one is running.
    func rescanOnActivate() {
        guard scanTask == nil else { return }
        Task { await scan() }
    }

    /// Once per launch: scans, compares with the features ready at the previous launch and stores the new set.
    /// True when Setup should open (first launch, or a feature stopped being ready).
    func checkAtLaunch() async -> Bool {
        guard !launchChecked else { return false }
        launchChecked = true
        await scan()
        let defaults = UserDefaults.standard
        let previous = defaults.stringArray(forKey: Self.previouslyReadyKey)
            .map { Set($0.compactMap(Feature.init(rawValue:))) }
        let now = SetupScreen.readyFeatures(states)
        defaults.set(now.map(\.rawValue).sorted(), forKey: Self.previouslyReadyKey)
        return SetupPolicy.shouldShowSetup(previouslyReady: previous, nowReady: now)
    }

    func unlock(_ feature: Feature) async {
        await install(SetupScreen.unlockOrder(for: [feature], in: states))
    }

    func unlockEverything() async {
        await install(SetupScreen.unlockOrder(for: Feature.allCases, in: states))
    }

    func uninstallHelper() async {
        guard !isWorking else { return }
        isWorking = true
        notice = nil
        do {
            try await installer.uninstallHelper()
        } catch InstallerError.canceled {
        } catch {
            errorMessage = error.localizedDescription
        }
        isWorking = false
        await scan()
    }

    func answerYes() {
        log.append("> y")
        installer.answerYes()
    }

    func cancelBrew() {
        installer.cancelBrew()
    }

    // MARK: - Private

    /// Runs the steps that can run now, in order, stopping at the first failure or after a step that continues
    /// outside Driveway. Errors go to the log while the log sheet is up, otherwise to an alert.
    private func install(_ order: [Requirement]) async {
        guard !isWorking else { return }
        isWorking = true
        notice = nil
        let now = SetupScreen.runNow(order)
        if now.contains(where: { Self.isBrew(InstallStep.for($0)) }) {
            log = []
            logShown = true
        }
        for requirement in now {
            do {
                try await installer.perform(InstallStep.for(requirement)) { [weak self] line in self?.log.append(line) }
            } catch InstallerError.canceled {
                if logShown { log.append("Canceled.") }
                break
            } catch {
                report(error.localizedDescription)
                break
            }
            if let next = Copy.afterHandoff(requirement) { notice = next }
        }
        isWorking = false
        await scan()
    }

    private func report(_ message: String) {
        if logShown { log.append(message) } else { errorMessage = message }
    }

    private func scanOnce() async {
        let inventory = await scanner.scan()
        self.inventory = inventory
        states = featureStates(inventory)
        diskManager.readyFeatures = SetupScreen.readyFeatures(states)
        // The helper was just installed or removed: bring the Disk Manager's view of it up to date.
        if (inventory.helperVersion != nil) != diskManager.helperReachable {
            Task { await diskManager.refresh() }
        }
    }

    private static func isBrew(_ step: InstallStep) -> Bool {
        if case .runBrew = step { return true }
        return false
    }
}

// The root helper: a launchd daemon serving app.driveway.helper.
import DrivewayCore
import DrivewayHelperKit
import DrivewayIPC
import Foundation
import Synchronization
import os

let logger = Logger(subsystem: "app.driveway.helper", category: "helper")
let paths = ToolPaths()

registerModifyDiskRight { logger.error("\($0, privacy: .public)") }

guard let inventory = DADiskInventory(runner: ProcessCommandRunner(timeout: .seconds(60)), paths: paths) else {
    logger.fault("Couldn't open a DiskArbitration session.")
    exit(1)
}

// The backend tools get a short timeout: a hung probe must not hold up every mount decision.
let backendProbe = BackendProbe(runner: ProcessCommandRunner(timeout: .seconds(30)))

/// Feature states, read by the service (also from DiskArbitration's approval callback): kept in memory and
/// refreshed in the background, never computed on the caller's thread.
let features = Mutex<[Feature: FeatureState]>(
    featureStates(HelperEnvironment.currentToolInventory(paths: paths, backend: .unavailable)))

/// Armed once the helper has adopted its old mounts and the disk watcher runs; until then nothing is evaluated
/// again (a drive still mounted from before a restart must be adopted, not taken over).
let trigger = Mutex<ReevaluationTrigger?>(nil)

/// Stores fresh feature states, then runs the plug-in decision again if a drive may now be mountable.
@Sendable func updateFeatures(backend: BackendAvailability) {
    let states = featureStates(HelperEnvironment.currentToolInventory(paths: paths, backend: backend))
    features.withLock { $0 = states }
    reevaluateIfNeeded()
}

/// Someone logged in, NTFS writing / ext drives became ready, or the helper was given Full Disk Access: drives
/// attached before that were left to macOS. The Full Disk Access probe is one open() and close(), so it runs with
/// the 5-second login check: a drive is taken over moments after the user allows the helper in System Settings.
@Sendable func reevaluateIfNeeded() {
    let user = HelperEnvironment.consoleUser()
    let states = features.withLock { $0 }
    let access = HelperEnvironment.fullDiskAccess()
    guard trigger.withLock({ $0?.update(user: user, features: states, fullDiskAccess: access) ?? false }) else { return }
    Task {
        logger.notice("Evaluating drives again: someone logged in, a feature became ready or Full Disk Access was granted.")
        for event in await service.reevaluateDrives() { listener.broadcast(event) }
    }
}

// Mounts keep the default time limit. Check, repair, backup and format run for as long as they take: stopping
// ntfsclone, e2fsck or ntfsfix half-way through a large drive would do more harm than waiting.
let service = HelperService(
    runner: ProcessCommandRunner(), unboundedRunner: ProcessCommandRunner(timeout: nil), auth: SystemAuthorizationVerifier(), inventory: inventory,
    settings: SettingsStore(), paths: paths, backendProbe: backendProbe, osBuild: HelperEnvironment.osBuild(),
    consoleUser: { HelperEnvironment.consoleUser() },
    features: { features.withLock { $0 } },
    // Setup asks for the backend after every step: refresh the features then, not 5 minutes later.
    backendChecked: { updateFeatures(backend: $0) },
    progress: { broadcast($0) },
    log: { logger.notice("\($0, privacy: .public)") })

/// Sends an event to every connected app and agent. A function, so the service can be handed it before the
/// listener exists.
@Sendable func broadcast(_ event: VolumeEvent) {
    listener.broadcast(event)
}

let listener = HelperListener(service: service, logger: logger)

guard let watcher = DiskWatcher(broadcast: { listener.broadcast($0) }, logger: logger) else {
    logger.fault("Couldn't open a DiskArbitration session for the disk watcher.")
    exit(1)
}

/// The backend as the service sees it (including a recorded FSKit failure), then the tools on disk: handling
/// `.backendStatus` calls `updateFeatures`.
@Sendable func refreshFeatures() async {
    _ = await service.handle(.backendStatus, authorization: nil)
}

Task {
    // Warm the backend cache, so the first disk event doesn't wait for bputil and friends.
    _ = await backendProbe.probe()
    await refreshFeatures()
    // Mounts from before a restart are Driveway's: record them before any disk event arrives.
    await service.adoptExistingMounts()
    watcher.start(service: service)
    listener.start()
    let states = features.withLock { $0 }
    let access = HelperEnvironment.fullDiskAccess()
    trigger.withLock {
        $0 = ReevaluationTrigger(user: HelperEnvironment.consoleUser(), features: states, fullDiskAccess: access)
    }
    let accessText = access.map { $0 ? "granted" : "missing: external drives stay with macOS" } ?? "unknown"
    logger.notice(
        "Driveway helper \(helperProtocolVersion, privacy: .public) started. Full Disk Access: \(accessText, privacy: .public).")
    while true {
        try? await Task.sleep(for: .seconds(300))
        await refreshFeatures()
    }
}

// Watches for a login: a drive attached at the login window was left to macOS and is taken over now.
Task {
    while true {
        try? await Task.sleep(for: .seconds(5))
        reevaluateIfNeeded()
    }
}

dispatchMain()

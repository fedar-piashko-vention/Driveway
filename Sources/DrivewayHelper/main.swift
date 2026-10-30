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

let service = HelperService(
    runner: ProcessCommandRunner(), auth: SystemAuthorizationVerifier(), inventory: inventory,
    settings: SettingsStore(), paths: paths, backendProbe: backendProbe, osBuild: HelperEnvironment.osBuild(),
    consoleUser: { HelperEnvironment.consoleUser() },
    features: { features.withLock { $0 } },
    log: { logger.notice("\($0, privacy: .public)") })

let listener = HelperListener(service: service, logger: logger)

guard let watcher = DiskWatcher(broadcast: { listener.broadcast($0) }, logger: logger) else {
    logger.fault("Couldn't open a DiskArbitration session for the disk watcher.")
    exit(1)
}

/// The backend as the service sees it (including a recorded FSKit failure), then the tools on disk.
@Sendable func refreshFeatures() async {
    var backend = BackendAvailability.unavailable
    if case .backend(let b) = await service.handle(.backendStatus, authorization: nil) { backend = b }
    let states = featureStates(HelperEnvironment.currentToolInventory(paths: paths, backend: backend))
    features.withLock { $0 = states }
}

Task {
    // Warm the backend cache, so the first disk event doesn't wait for bputil and friends.
    _ = await backendProbe.probe()
    await refreshFeatures()
    // Mounts from before a restart are Driveway's: record them before any disk event arrives.
    await service.adoptExistingMounts()
    watcher.start(service: service)
    listener.start()
    logger.notice("Driveway helper \(helperProtocolVersion, privacy: .public) started.")
    while true {
        try? await Task.sleep(for: .seconds(60))
        await refreshFeatures()
    }
}

dispatchMain()

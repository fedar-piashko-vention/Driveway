import DrivewayCore
import DrivewayIPC
import Foundation
import Observation
import os

/// The Disk Manager's state: the helper's volume list kept current by its events, the selected drive and the
/// settings. Every helper error ends up in `errorMessage`, which the window shows as an alert.
@MainActor
@Observable
final class DiskManagerModel {
    var volumes: [Volume] = []
    var selection: String?
    var settings = DrivewaySettings()
    var errorMessage: String?
    /// False after a request failed to reach the helper; the window then offers Setup.
    private(set) var helperReachable = true
    /// True once the helper's settings arrived. Settings are never sent before that, so defaults can't overwrite them.
    private(set) var settingsLoaded = false
    /// Drives with an operation (eject, fix & mount, check, repair, back up) in flight.
    private(set) var busy: Set<String> = []
    /// The latest check or repair report per drive, by BSD name.
    private(set) var reports: [String: CheckReport] = [:]
    /// Where the latest backup of each drive was saved, by BSD name.
    private(set) var backups: [String: String] = [:]

    @ObservationIgnored private let client: HelperClient
    @ObservationIgnored private var eventsTask: Task<Void, Never>?
    @ObservationIgnored private var gate = RefreshGate()
    /// The one pending refresh after the helper was unreachable.
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private let logger = Logger(subsystem: "app.driveway.Driveway", category: "model")

    init(client: HelperClient = HelperClient()) {
        self.client = client
    }

    var selectedVolume: Volume? {
        volumes.first { $0.bsdName == selection }
    }

    /// Connects to the helper and starts applying its events. Safe to call more than once.
    func start() {
        guard eventsTask == nil else { return }
        client.connect()
        let events = client.events
        eventsTask = Task { [weak self] in
            for await event in events {
                self?.apply(event)
            }
        }
    }

    /// Reloads the volume list and settings. A reply that events or settings changes have overtaken is dropped.
    func refresh() async {
        let token = gate.beginRefresh()
        guard let listed = await perform(.listVolumes) else { return }
        if case .volumes(let volumes) = listed {
            if gate.acceptsVolumes(from: token) { self.volumes = volumes }
        } else {
            unexpected(listed, for: .listVolumes)
        }
        guard let fetched = await perform(.getSettings) else { return }
        if case .settings(let settings) = fetched {
            if gate.acceptsSettings(from: token) {
                self.settings = settings
                settingsLoaded = true
            }
        } else {
            unexpected(fetched, for: .getSettings)
        }
    }

    func apply(_ e: VolumeEvent) {
        gate.eventApplied()
        helperReachable = true
        volumes = e.applied(to: volumes)
    }

    /// Opens a volume named in a `driveway://volume/<bsd>` link.
    func open(_ url: URL) {
        guard let bsd = VolumeList.bsdName(from: url) else { return }
        selection = bsd
    }

    func eject(_ volume: Volume) async {
        await operate(on: volume, .eject(volume.bsdName), authorized: false)
    }

    func fixAndMount(_ volume: Volume) async {
        await operate(on: volume, .fixAndMount(volume.bsdName), authorized: true)
    }

    /// Checks the drive without changing it. The report lands in `reports`.
    func check(_ volume: Volume) async {
        await runReport(on: volume, .check(volume.bsdName), authorized: false)
    }

    /// Repairs the drive; `force` answers yes to every question (ext only). The report lands in `reports`.
    func repair(_ volume: Volume, force: Bool) async {
        await runReport(on: volume, .repair(volume.bsdName, force: force), authorized: true)
    }

    /// Clones an NTFS drive into the image file at `path`.
    func backUp(_ volume: Volume, to path: String) async {
        let request = HelperRequest.backup(volume.bsdName, imagePath: path)
        guard let response = await operate(on: volume, request, authorized: true) else { return }
        if case .ok = response {
            backups[volume.bsdName] = path
        } else {
            unexpected(response, for: request)
        }
    }

    func isAlwaysReadOnly(_ volume: Volume) -> Bool {
        settings.alwaysReadOnly.contains(volume.settingsKey)
    }

    /// Adds or removes the drive's settings key, then saves; on failure the toggle goes back.
    func setAlwaysReadOnly(_ on: Bool, for volume: Volume) async {
        let key = volume.settingsKey
        guard settingsLoaded, settings.alwaysReadOnly.contains(key) != on else { return }
        setKey(key, on)
        if await saveSettings() == false {
            setKey(key, !on)
        }
    }

    func setAutoMountNTFS(_ on: Bool) async {
        guard settingsLoaded, settings.autoMountNTFS != on else { return }
        settings.autoMountNTFS = on
        if await saveSettings() == false {
            settings.autoMountNTFS = !on
        }
    }

    // MARK: - Private

    /// Sends the current settings. While this runs, and after it, refreshes started earlier don't replace them.
    private func saveSettings() async -> Bool {
        gate.settingsWriteStarted()
        defer { gate.settingsWriteFinished() }
        return await perform(.setSettings(settings)) != nil
    }

    /// Tries `refresh()` again once the client's reconnect back-off has passed. At most one retry is pending.
    private func scheduleRetry() {
        guard retryTask == nil else { return }
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: HelperClient.backoff)
            guard let self else { return }
            self.retryTask = nil
            await self.refresh()
        }
    }

    private func setKey(_ key: String, _ on: Bool) {
        if on { settings.alwaysReadOnly.insert(key) } else { settings.alwaysReadOnly.remove(key) }
    }

    /// Runs a drive operation, then reloads the list (the helper's events may lag behind its reply). Returns the
    /// helper's reply, or nil if the drive was busy or the request failed or was canceled.
    @discardableResult
    private func operate(on volume: Volume, _ request: HelperRequest, authorized: Bool) async -> HelperResponse? {
        guard busy.insert(volume.bsdName).inserted else { return nil }
        defer { busy.remove(volume.bsdName) }
        guard let response = await perform(request, authorized: authorized) else { return nil }
        await refresh()
        return response
    }

    private func runReport(on volume: Volume, _ request: HelperRequest, authorized: Bool) async {
        guard let response = await operate(on: volume, request, authorized: authorized) else { return }
        if case .report(let report) = response {
            reports[volume.bsdName] = report
        } else {
            unexpected(response, for: request)
        }
    }

    /// Sends a request. Returns nil, after recording why, when it couldn't be sent, the user canceled the password
    /// prompt, or the helper answered with an error.
    private func perform(_ request: HelperRequest, authorized: Bool = false) async -> HelperResponse? {
        let response: HelperResponse
        do {
            response = try await client.send(request, authorized: authorized)
        } catch HelperClientError.unreachable(let detail) {
            logger.notice("The helper is unreachable: \(detail, privacy: .public)")
            helperReachable = false
            scheduleRetry()
            return nil
        } catch AuthorizerError.canceled {
            return nil
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
        helperReachable = true
        if case .error(let error) = response {
            errorMessage = error.message
            return nil
        }
        return response
    }

    private func unexpected(_ response: HelperResponse, for request: HelperRequest) {
        let sent = String(describing: request)
        let got = String(describing: response)
        logger.error("Unexpected reply to \(sent, privacy: .public): \(got, privacy: .public)")
        errorMessage = "Driveway's helper sent an unexpected reply. Update Driveway."
    }
}

extension HelperError {
    /// What the alert says when the helper refuses or fails a request.
    var message: String {
        switch self {
        case .protectedDisk: "Driveway doesn't change internal, system or Apple-formatted disks."
        case .notAuthorized: "The administrator authorization wasn't accepted. Try again."
        case .unknownVolume: "That drive is no longer connected."
        case .toolMissing(let path): "A tool Driveway needs is missing: \(path). Open Setup to install it."
        case .commandFailed(let message): message
        case .validation(let error): "The format settings aren't valid (\(error))."
        }
    }
}

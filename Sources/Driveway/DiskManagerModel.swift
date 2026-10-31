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
    /// Drives with an operation (eject, fix & mount) in flight.
    private(set) var busy: Set<String> = []

    @ObservationIgnored private let client: HelperClient
    @ObservationIgnored private var eventsTask: Task<Void, Never>?
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

    func refresh() async {
        guard let listed = await perform(.listVolumes) else { return }
        if case .volumes(let volumes) = listed {
            self.volumes = volumes
        } else {
            unexpected(listed, for: .listVolumes)
        }
        guard let fetched = await perform(.getSettings) else { return }
        if case .settings(let settings) = fetched {
            self.settings = settings
            settingsLoaded = true
        } else {
            unexpected(fetched, for: .getSettings)
        }
    }

    func apply(_ e: VolumeEvent) {
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

    func isAlwaysReadOnly(_ volume: Volume) -> Bool {
        settings.alwaysReadOnly.contains(volume.settingsKey)
    }

    /// Adds or removes the drive's settings key, then saves; on failure the toggle goes back.
    func setAlwaysReadOnly(_ on: Bool, for volume: Volume) async {
        let key = volume.settingsKey
        guard settingsLoaded, settings.alwaysReadOnly.contains(key) != on else { return }
        setKey(key, on)
        if await perform(.setSettings(settings)) == nil {
            setKey(key, !on)
        }
    }

    func setAutoMountNTFS(_ on: Bool) async {
        guard settingsLoaded, settings.autoMountNTFS != on else { return }
        settings.autoMountNTFS = on
        if await perform(.setSettings(settings)) == nil {
            settings.autoMountNTFS = !on
        }
    }

    // MARK: - Private

    private func setKey(_ key: String, _ on: Bool) {
        if on { settings.alwaysReadOnly.insert(key) } else { settings.alwaysReadOnly.remove(key) }
    }

    /// Runs a drive operation, then reloads the list (the helper's events may lag behind its reply).
    private func operate(on volume: Volume, _ request: HelperRequest, authorized: Bool) async {
        guard busy.insert(volume.bsdName).inserted else { return }
        defer { busy.remove(volume.bsdName) }
        guard await perform(request, authorized: authorized) != nil else { return }
        await refresh()
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

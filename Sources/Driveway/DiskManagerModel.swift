import DrivewayCore
import DrivewayIPC
import Foundation
import Observation
import os

/// A format that is running. It outlives the volume: while the disk is erased macOS reports its partitions gone,
/// and the window must still show that Driveway is working.
struct FormatInProgress: Equatable {
    var label: String
    var bsdName: String
    var wholeDisk: String
    /// What the drive becomes, e.g. "NTFS · GPT · whole disk".
    var description: String
}

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
    /// The format in flight, if any. Set from the moment it's handed to the model until the list is current again.
    private(set) var formatting: FormatInProgress?
    /// The features the Setup scan found ready. The Format tab only offers the filesystems these make usable.
    /// Everything counts as ready until the scanner (which fills this in) exists.
    var readyFeatures: Set<Feature> = Set(Feature.allCases)

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
            if gate.acceptsVolumes(from: token) {
                self.volumes = volumes
                // BSD names get reused by later drives, so a gone drive's results must not carry over.
                let present = Set(volumes.map(\.bsdName))
                reports = reports.filter { present.contains($0.key) }
                backups = backups.filter { present.contains($0.key) }
            }
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

    /// Checks the drive. NTFS and ext drives are unmounted while it runs. The report lands in `reports`.
    func check(_ volume: Volume) async {
        await runReport(on: volume, .check(volume.bsdName), authorized: false)
    }

    /// Repairs the drive; `force` answers yes to every question (ext only). The report lands in `reports`.
    func repair(_ volume: Volume, force: Bool) async {
        await runReport(on: volume, .repair(volume.bsdName, force: force), authorized: true)
    }

    /// Clones an NTFS drive into the image file at `path`.
    /// Refuses a target on the drive itself: the image can't be a backup there, and it would grow while it's written.
    func backUp(_ volume: Volume, to path: String) async {
        if VolumeList.isInside(path: Self.resolved(path), mountPoint: volume.mountPoint.map(Self.resolved)) {
            errorMessage = "Save the backup on a different drive."
            return
        }
        let request = HelperRequest.backup(volume.bsdName, imagePath: path)
        guard case .reply(let response) = await operate(on: volume, request, authorized: true) else { return }
        if case .ok = response {
            backups[volume.bsdName] = path
        } else {
            unexpected(response, for: request)
        }
    }

    /// Erases and formats the drive (or its whole disk). Afterwards the drive's BSD name may have changed, or the
    /// volume may have gone: the list is reloaded, and a selection that no longer exists moves to the new volume on
    /// the same disk. The caller closes its confirmation sheet when this returns, however it ended.
    func format(_ request: FormatRequest, volume: Volume) async {
        guard formatting == nil, !busy.contains(volume.bsdName) else { return }
        formatting = FormatInProgress(
            label: volume.label, bsdName: volume.bsdName, wholeDisk: volume.wholeDisk,
            description: FormatForm.summary(of: request))
        defer { formatting = nil }
        let result = await operate(on: volume, .format(request), authorized: true)
        if case .reply(let response) = result {
            switch response {
            case .ok, .volume(nil): break
            case .volume(let formatted?):
                if volumes.contains(where: { $0.bsdName == formatted.bsdName }) { selection = formatted.bsdName }
            default: unexpected(response, for: .format(request))
            }
        }
        if selectedVolume == nil, selection == volume.bsdName {
            selection = volumes.first { $0.wholeDisk == volume.wholeDisk }?.bsdName
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

    /// The path with symlinks in its folders resolved (the file itself may not exist yet).
    private static func resolved(_ path: String) -> String {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let folder = url.deletingLastPathComponent().resolvingSymlinksInPath()
        return url.pathComponents.count > 1 ? folder.appendingPathComponent(url.lastPathComponent).path : url.path
    }

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

    /// How a drive operation ended.
    private enum Operation {
        /// The helper answered; the drive's list was reloaded.
        case reply(HelperResponse)
        /// The helper answered with an error (already shown). The drive's list was reloaded, since a failed operation
        /// can leave it unmounted or mounted differently.
        case failed
        /// Nothing happened: the drive was busy, the request couldn't be sent, or the user canceled the prompt.
        case notRun
    }

    /// Runs a drive operation, then reloads the list (the helper's events may lag behind its reply).
    @discardableResult
    private func operate(on volume: Volume, _ request: HelperRequest, authorized: Bool) async -> Operation {
        guard busy.insert(volume.bsdName).inserted else { return .notRun }
        defer { busy.remove(volume.bsdName) }
        switch await send(request, authorized: authorized) {
        case .notSent:
            return .notRun
        case .helperError:
            await refresh()
            return .failed
        case .reply(let response):
            await refresh()
            return .reply(response)
        }
    }

    private func runReport(on volume: Volume, _ request: HelperRequest, authorized: Bool) async {
        switch await operate(on: volume, request, authorized: authorized) {
        case .notRun:
            break
        case .failed:
            // The earlier report is out of date now, and would sit next to the error.
            reports[volume.bsdName] = nil
        case .reply(.report(let report)):
            reports[volume.bsdName] = report
        case .reply(let response):
            unexpected(response, for: request)
        }
    }

    /// Sends a request. Returns nil, after recording why, when it couldn't be sent, the user canceled the password
    /// prompt, or the helper answered with an error.
    private func perform(_ request: HelperRequest, authorized: Bool = false) async -> HelperResponse? {
        if case .reply(let response) = await send(request, authorized: authorized) { return response }
        return nil
    }

    private enum Sent {
        case reply(HelperResponse)
        /// The helper answered with an error, now in `errorMessage`.
        case helperError
        /// Unreachable, canceled, or failed on the way; the reason was recorded unless the user canceled.
        case notSent
    }

    private func send(_ request: HelperRequest, authorized: Bool) async -> Sent {
        let response: HelperResponse
        do {
            response = try await client.send(request, authorized: authorized)
        } catch HelperClientError.unreachable(let detail) {
            logger.notice("The helper is unreachable: \(detail, privacy: .public)")
            helperReachable = false
            scheduleRetry()
            return .notSent
        } catch AuthorizerError.canceled {
            return .notSent
        } catch {
            errorMessage = error.localizedDescription
            return .notSent
        }
        helperReachable = true
        if case .error(let error) = response {
            errorMessage = error.message
            return .helperError
        }
        return .reply(response)
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
        case .validation(let error): FormatMessages.text(for: error)
        }
    }
}

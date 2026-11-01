import AppKit
import DrivewayCore
import DrivewayIPC
import UserNotifications
import os

/// The per-user LaunchAgent: listens for `VolumeEvent`s from the root helper and turns them into user notifications.
/// No windows, no Dock icon (`LSUIElement`).
@main
@MainActor
struct AgentApp {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let agent = Agent()
        agent.start()
        app.run()
    }
}

@MainActor
final class Agent {
    static let notifiedDriversKey = "notifiedDrivers"

    private let logger = Logger(subsystem: "app.driveway.agent", category: "agent")
    private let notifier = Notifier()
    private var inFlight: Set<String> = []
    private lazy var link = HelperLink(logger: logger) { [weak self] event in self?.handle(event) }

    func start() {
        notifier.start()
        link.connect()
    }

    func handle(_ event: VolumeEvent) {
        switch event {
        case .mountedReadOnly(let volume, let reason):
            let (health, error) = reason.healthAndError
            let content = NotificationContent.readOnly(
                label: volume.label, bsdName: volume.bsdName, health: health, error: error)
            Task { await notifier.post(content) }
        case .mountFailed(let volume, let message):
            let content = NotificationContent.mountFailed(label: volume.label, message: message)
            Task { await notifier.post(content) }
        case .backedOff(let volume, let driver):
            announceOnce(driver: driver, content: .backedOff(label: volume.label, driver: driver))
        case .mounted, .removed, .progress:
            break
        }
    }

    /// Announces a driver once per user. The driver is recorded only after the notification was delivered, so a denied
    /// or failed post doesn't use up the notice. `inFlight` stops two events for one driver racing to post twice.
    private func announceOnce(driver: String, content: NotificationContent) {
        guard !notifiedDrivers.contains(driver), inFlight.insert(driver).inserted else { return }
        Task {
            if await notifier.post(content) { markNotified(driver: driver) }
            inFlight.remove(driver)
        }
    }

    private var notifiedDrivers: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: Self.notifiedDriversKey) ?? [])
    }

    private func markNotified(driver: String) {
        UserDefaults.standard.set((notifiedDrivers.union([driver])).sorted(), forKey: Self.notifiedDriversKey)
    }
}

/// Posts notifications and opens Driveway when one is clicked.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    nonisolated private static let urlKey = "openURL"
    nonisolated private static let appURL = URL(string: "driveway://")!
    private let logger = Logger(subsystem: "app.driveway.agent", category: "notifier")

    /// `UNUserNotificationCenter` traps in a process that isn't inside an app bundle (e.g. `swift run`).
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    func start() {
        guard let center else {
            logger.error("Not running from an app bundle; notifications are disabled.")
            return
        }
        center.delegate = self
        Task {
            do {
                if try await center.requestAuthorization(options: [.alert, .sound]) == false {
                    logger.notice("The user has not allowed notifications.")
                }
            } catch {
                logger.error("Notification authorization failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Returns true once the system accepted the notification.
    func post(_ content: NotificationContent) async -> Bool {
        guard let center else { return false }
        let note = UNMutableNotificationContent()
        note.title = content.title
        note.body = content.body
        note.sound = .default
        if let url = content.openURL { note.userInfo = [Self.urlKey: url.absoluteString] }
        do {
            try await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: note, trigger: nil))
            return true
        } catch {
            logger.error("Couldn't post a notification: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Show banners even while the agent counts as the foreground app.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    /// A click opens the notification's URL, or just Driveway when it has none.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        let target = response.notification.request.content.userInfo[Self.urlKey] as? String
        let url = target.flatMap(URL.init(string:)) ?? Self.appURL
        await MainActor.run { _ = NSWorkspace.shared.open(url) }
    }
}

/// The agent's connection to the helper. The helper only learns about a client when it receives a message, so every
/// (re)connection sends one request to register.
@MainActor
final class HelperLink {
    static let backoff: Duration = .seconds(5)

    private let logger: Logger
    private let receiver: EventReceiver
    private var connection: NSXPCConnection?
    /// True while a re-registration after an interruption waits out the back-off.
    private var registerPending = false

    init(logger: Logger, onEvent: @escaping @MainActor (VolumeEvent) -> Void) {
        self.logger = logger
        self.receiver = EventReceiver(onEvent: onEvent)
    }

    func connect() {
        let connection = NSXPCConnection(machServiceName: MachServices.helper, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: DrivewayHelperXPC.self)
        connection.exportedInterface = NSXPCInterface(with: DrivewayEventsXPC.self)
        connection.exportedObject = receiver
        // The helper restarted, or refused this agent: the connection object is still usable, so register again
        // after the back-off.
        connection.interruptionHandler = { [weak self] in
            Task { @MainActor in self?.registerAfterBackoff() }
        }
        connection.invalidationHandler = { [weak self, weak connection] in
            Task { @MainActor in
                guard let self, let connection, self.connection === connection else { return }
                self.logger.notice("The helper connection was invalidated; reconnecting.")
                self.connection = nil
                try? await Task.sleep(for: Self.backoff)
                self.connect()
            }
        }
        self.connection = connection
        connection.resume()
        register()
    }

    /// A refusal arrives as an interruption, and the helper may never accept this copy (for example once Driveway was
    /// replaced on disk while the agent runs). Registering again at once would then spin, so wait first, with at most
    /// one re-registration pending.
    private func registerAfterBackoff() {
        guard !registerPending else { return }
        registerPending = true
        Task { [weak self] in
            try? await Task.sleep(for: Self.backoff)
            guard let self else { return }
            self.registerPending = false
            self.register()
        }
    }

    private func register() {
        guard let data = try? JSONEncoder().encode(HelperRequest.helperVersion) else { return }
        let logger = logger
        let proxy = connection?.remoteObjectProxyWithErrorHandler { error in
            logger.error("Couldn't reach the helper: \(error.localizedDescription, privacy: .public)")
        }
        (proxy as? DrivewayHelperXPC)?.perform(data, authorization: nil) { _ in }
    }
}

/// Exported to the helper. XPC calls arrive on an arbitrary queue, so events hop to the main actor.
final class EventReceiver: NSObject, DrivewayEventsXPC, Sendable {
    private let logger = Logger(subsystem: "app.driveway.agent", category: "events")
    private let onEvent: @MainActor (VolumeEvent) -> Void

    init(onEvent: @escaping @MainActor (VolumeEvent) -> Void) {
        self.onEvent = onEvent
    }

    func volumeEvent(_ event: Data) {
        do {
            let decoded = try JSONDecoder().decode(VolumeEvent.self, from: event)
            let onEvent = onEvent
            Task { @MainActor in onEvent(decoded) }
        } catch {
            logger.error("Couldn't decode a volume event: \(error.localizedDescription, privacy: .public)")
        }
    }
}

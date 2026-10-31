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
    private lazy var link = HelperLink(logger: logger) { [weak self] event in self?.handle(event) }

    func start() {
        notifier.start()
        link.connect()
    }

    func handle(_ event: VolumeEvent) {
        switch event {
        case .mountedReadOnly(let volume, let reason):
            let (health, error) = reason.healthAndError
            notifier.post(
                .readOnly(label: volume.label, bsdName: volume.bsdName, health: health, error: error))
        case .mountFailed(let volume, let message):
            notifier.post(.mountFailed(label: volume.label, message: message))
        case .backedOff(let volume, let driver):
            guard markNotified(driver: driver) else { return }
            notifier.post(.backedOff(label: volume.label, driver: driver))
        case .mounted, .removed:
            break
        }
    }

    /// True the first time a driver is seen. The set persists, so each driver is announced once per user.
    private func markNotified(driver: String) -> Bool {
        let defaults = UserDefaults.standard
        var seen = Set(defaults.stringArray(forKey: Self.notifiedDriversKey) ?? [])
        guard seen.insert(driver).inserted else { return false }
        defaults.set(seen.sorted(), forKey: Self.notifiedDriversKey)
        return true
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
        let logger = logger
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                logger.error("Notification authorization failed: \(error.localizedDescription, privacy: .public)")
            } else if !granted {
                logger.notice("The user has not allowed notifications.")
            }
        }
    }

    func post(_ content: NotificationContent) {
        guard let center else { return }
        let note = UNMutableNotificationContent()
        note.title = content.title
        note.body = content.body
        note.sound = .default
        if let url = content.openURL { note.userInfo = [Self.urlKey: url.absoluteString] }
        let logger = logger
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: note, trigger: nil)) { error in
            if let error {
                logger.error("Couldn't post a notification: \(error.localizedDescription, privacy: .public)")
            }
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

    init(logger: Logger, onEvent: @escaping @MainActor (VolumeEvent) -> Void) {
        self.logger = logger
        self.receiver = EventReceiver(onEvent: onEvent)
    }

    func connect() {
        let connection = NSXPCConnection(machServiceName: MachServices.helper, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: DrivewayHelperXPC.self)
        connection.exportedInterface = NSXPCInterface(with: DrivewayEventsXPC.self)
        connection.exportedObject = receiver
        // The helper restarted: this connection object is still usable, so just register again.
        connection.interruptionHandler = { [weak self] in
            Task { @MainActor in self?.register() }
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
    private let onEvent: @MainActor (VolumeEvent) -> Void

    init(onEvent: @escaping @MainActor (VolumeEvent) -> Void) {
        self.onEvent = onEvent
    }

    func volumeEvent(_ event: Data) {
        guard let decoded = try? JSONDecoder().decode(VolumeEvent.self, from: event) else { return }
        let onEvent = onEvent
        Task { @MainActor in onEvent(decoded) }
    }
}

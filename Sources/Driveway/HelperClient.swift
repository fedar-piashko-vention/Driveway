import DrivewayIPC
import Foundation
import Synchronization
import os

enum HelperClientError: Error, LocalizedError {
    /// The helper isn't installed, isn't running, or refused this app.
    case unreachable(String)
    /// The helper's reply couldn't be read.
    case badReply

    var errorDescription: String? {
        switch self {
        case .unreachable(let detail): "Couldn't reach Driveway's helper: \(detail)"
        case .badReply: "Driveway's helper sent a reply this app can't read. Update Driveway."
        }
    }
}

/// The app's connection to the root helper: sends requests and receives `VolumeEvent`s. Connects the same way as
/// the agent: the helper only learns about a client when it receives a message, so every (re)connection sends
/// `helperVersion` to register, and an invalidated connection is replaced after a back-off.
final class HelperClient: @unchecked Sendable {
    static let backoff: Duration = .seconds(5)
    private static let prompt = "Driveway needs an administrator's password to change this drive."

    let events: AsyncStream<VolumeEvent>
    private let receiver: EventReceiver
    private let logger = Logger(subsystem: "app.driveway.Driveway", category: "helper")
    /// The current connection; nil before `connect()` and while waiting to reconnect.
    private let connection = Mutex<NSXPCConnection?>(nil)
    /// True while a re-registration after an interruption waits out the back-off.
    private let registerPending = Mutex(false)

    init() {
        let (events, continuation) = AsyncStream<VolumeEvent>.makeStream()
        self.events = events
        self.receiver = EventReceiver(continuation: continuation)
    }

    /// Opens the connection if there isn't one, so events start arriving.
    func connect() {
        _ = currentConnection()
    }

    func send(_ r: HelperRequest, authorized: Bool) async throws -> HelperResponse {
        let request = try JSONEncoder().encode(r)
        var authorization: Data?
        if authorized {
            // The administrator prompt blocks its thread until the user answers.
            authorization = try await Task.detached(priority: .userInitiated) {
                try Authorizer.externalForm(prompt: Self.prompt)
            }.value
        }
        defer { if let authorization { Authorizer.release(authorization) } }

        let connection = currentConnection()
        let reply: Data = try await withCheckedThrowingContinuation { continuation in
            let once = ResumeOnce(continuation)
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                once.resume(with: .failure(HelperClientError.unreachable(error.localizedDescription)))
            }
            guard let helper = proxy as? DrivewayHelperXPC else {
                once.resume(with: .failure(HelperClientError.unreachable("unexpected proxy type")))
                return
            }
            helper.perform(request, authorization: authorization) { data in
                once.resume(with: .success(data))
            }
        }
        do {
            return try JSONDecoder().decode(HelperResponse.self, from: reply)
        } catch {
            logger.error("Couldn't decode a helper reply: \(error.localizedDescription, privacy: .public)")
            throw HelperClientError.badReply
        }
    }

    private func currentConnection() -> NSXPCConnection {
        let (connection, isNew) = self.connection.withLock { current -> (NSXPCConnection, Bool) in
            if let current { return (current, false) }
            let made = makeConnection()
            current = made
            return (made, true)
        }
        if isNew {
            connection.resume()
            register(connection)
        }
        return connection
    }

    private func makeConnection() -> NSXPCConnection {
        let connection = NSXPCConnection(machServiceName: MachServices.helper, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: DrivewayHelperXPC.self)
        connection.exportedInterface = NSXPCInterface(with: DrivewayEventsXPC.self)
        connection.exportedObject = receiver
        // The helper restarted, or refused this app: the connection object is still usable, so register again
        // after the back-off.
        connection.interruptionHandler = { [weak self] in
            self?.registerAfterBackoff()
        }
        connection.invalidationHandler = { [weak self, weak connection] in
            guard let self, let connection else { return }
            let invalidated = ObjectIdentifier(connection)
            let wasCurrent = self.connection.withLock { current in
                guard let live = current, ObjectIdentifier(live) == invalidated else { return false }
                current = nil
                return true
            }
            guard wasCurrent else { return }
            self.logger.notice("The helper connection was invalidated; reconnecting.")
            Task { [weak self] in
                try? await Task.sleep(for: Self.backoff)
                self?.connect()
            }
        }
        return connection
    }

    /// A refusal arrives as an interruption, and the helper may never accept this copy of the app (for example once
    /// Driveway was replaced on disk while it runs). Registering again at once would then spin, so wait first, with
    /// at most one re-registration pending.
    private func registerAfterBackoff() {
        let alreadyPending = registerPending.withLock { pending in
            defer { pending = true }
            return pending
        }
        guard !alreadyPending else { return }
        Task { [weak self] in
            try? await Task.sleep(for: Self.backoff)
            guard let self else { return }
            self.registerPending.withLock { $0 = false }
            // An interrupted connection stays current; an invalidated one has been replaced (and registered).
            if let current = self.connection.withLock({ $0 }) { self.register(current) }
        }
    }

    private func register(_ connection: NSXPCConnection) {
        guard let data = try? JSONEncoder().encode(HelperRequest.helperVersion) else { return }
        let logger = logger
        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            logger.error("Couldn't reach the helper: \(error.localizedDescription, privacy: .public)")
        }
        (proxy as? DrivewayHelperXPC)?.perform(data, authorization: nil) { _ in }
    }
}

/// Exported to the helper. XPC delivers a connection's messages in order on one queue, and the continuation may be
/// fed from any thread, so events go straight into the stream.
private final class EventReceiver: NSObject, DrivewayEventsXPC, Sendable {
    private let logger = Logger(subsystem: "app.driveway.Driveway", category: "events")
    private let continuation: AsyncStream<VolumeEvent>.Continuation

    init(continuation: AsyncStream<VolumeEvent>.Continuation) {
        self.continuation = continuation
    }

    func volumeEvent(_ event: Data) {
        do {
            continuation.yield(try JSONDecoder().decode(VolumeEvent.self, from: event))
        } catch {
            logger.error("Couldn't decode a volume event: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// Both the proxy's error handler and the reply can fire for one call; the continuation is resumed by the first.
private final class ResumeOnce: Sendable {
    private let continuation: Mutex<CheckedContinuation<Data, any Error>?>

    init(_ continuation: CheckedContinuation<Data, any Error>) {
        self.continuation = Mutex(continuation)
    }

    func resume(with result: Result<Data, any Error>) {
        continuation.withLock { $0.take() }?.resume(with: result)
    }
}

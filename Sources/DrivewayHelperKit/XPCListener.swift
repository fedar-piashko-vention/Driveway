import DrivewayCore
import DrivewayIPC
import Foundation
import Security
import os

/// The helper's Mach service. Accepts only the Driveway app and its agent, as decided by `CallerPolicy`
/// from the peer's code signature (looked up by audit token, never by PID) and the state of the installed
/// bundle. Keeps the accepted connections so volume events can be pushed to them.
public final class HelperListener: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    public static let bundleURL = URL(fileURLWithPath: "/Applications/Driveway.app")

    private let listener: NSXPCListener
    private let service: HelperService
    private let logger: Logger
    private let lock = NSLock()
    private var clients: [ObjectIdentifier: NSXPCConnection] = [:]

    public init(service: HelperService, logger: Logger) {
        self.listener = NSXPCListener(machServiceName: MachServices.helper)
        self.service = service
        self.logger = logger
        super.init()
        listener.delegate = self
    }

    public func start() {
        listener.resume()
    }

    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard let caller = Self.caller(of: connection) else {
            logger.error("Refused a connection: couldn't read the caller's code signature.")
            return false
        }
        let bundleOwner = CallerPolicy.lstatResult(Self.bundleURL.path)?.uid ?? UInt32.max
        let writable = CallerPolicy.bundleIsWritableByNonRoot(at: Self.bundleURL)
        guard CallerPolicy.accept(
            signingIdentifier: caller.identifier, executablePath: caller.executablePath, bundleOwnerUID: bundleOwner,
            bundleWritableByNonRoot: writable)
        else {
            logger.error(
                "Refused \(caller.identifier ?? "unsigned", privacy: .public) at \(caller.executablePath, privacy: .public) (bundle owner \(bundleOwner), writable by others: \(writable)).")
            return false
        }
        if let id = caller.identifier {
            // Checked again on every message, so a process can't swap in after the connection is accepted.
            connection.setCodeSigningRequirement("identifier \"\(id)\"")
        }
        connection.exportedInterface = NSXPCInterface(with: DrivewayHelperXPC.self)
        connection.exportedObject = HelperEndpoint(service: service)
        connection.remoteObjectInterface = NSXPCInterface(with: DrivewayEventsXPC.self)
        let key = ObjectIdentifier(connection)
        let forget: @Sendable () -> Void = { [weak self] in self?.remove(key) }
        connection.invalidationHandler = forget
        connection.interruptionHandler = forget
        lock.withLock { clients[key] = connection }
        connection.resume()
        return true
    }

    private func remove(_ key: ObjectIdentifier) {
        lock.withLock { _ = clients.removeValue(forKey: key) }
    }

    /// Pushes an event to every connected client. Delivery failures are ignored; the client reconnects.
    public func broadcast(_ e: VolumeEvent) {
        guard let data = try? JSONEncoder().encode(e) else { return }
        let connections = lock.withLock { Array(clients.values) }
        for c in connections {
            (c.remoteObjectProxyWithErrorHandler { _ in } as? DrivewayEventsXPC)?.volumeEvent(data)
        }
    }

    struct Caller {
        var identifier: String?
        var executablePath: String
    }

    /// The peer's signing identifier and main executable, from its audit token. Nil if the code can't be
    /// found or its signature isn't valid.
    static func caller(of connection: NSXPCConnection) -> Caller? {
        guard let value = connection.value(forKey: "auditToken") as? NSValue else { return nil }
        var token = audit_token_t()
        value.getValue(&token, size: MemoryLayout<audit_token_t>.size)
        let tokenData = withUnsafeBytes(of: &token) { Data($0) }
        let attributes = [kSecGuestAttributeAudit as String: tokenData] as CFDictionary
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code,
              SecCodeCheckValidity(code, [], nil) == errSecSuccess
        else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
            == errSecSuccess,
            let dict = info as? [String: Any]
        else { return nil }
        let identifier = dict[kSecCodeInfoIdentifier as String] as? String
        // SecCodeCopyPath gives the bundle for bundled code; the policy compares the main executable.
        if let executable = dict[kSecCodeInfoMainExecutable as String] as? URL {
            return Caller(identifier: identifier, executablePath: executable.path)
        }
        var url: CFURL?
        guard SecCodeCopyPath(staticCode, [], &url) == errSecSuccess, let url else { return nil }
        return Caller(identifier: identifier, executablePath: (url as URL).path)
    }
}

/// The object a client calls. Decodes the request, runs it on the service and replies with the response.
final class HelperEndpoint: NSObject, DrivewayHelperXPC, Sendable {
    let service: HelperService

    init(service: HelperService) {
        self.service = service
    }

    func perform(_ request: Data, authorization: Data?, reply: @escaping (Data) -> Void) {
        let reply = UncheckedReply(send: reply)
        let service = self.service
        Task {
            let response: HelperResponse
            if let decoded = try? JSONDecoder().decode(HelperRequest.self, from: request) {
                response = await service.handle(decoded, authorization: authorization)
            } else {
                response = .error(.commandFailed("The helper couldn't read the request. Update Driveway."))
            }
            reply.send((try? JSONEncoder().encode(response)) ?? Data())
        }
    }
}

/// XPC reply blocks may be called from any thread, once.
private struct UncheckedReply: @unchecked Sendable {
    let send: (Data) -> Void
}

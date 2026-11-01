import DrivewayIPC
import Foundation
import Security
import Synchronization

enum AuthorizerError: Error, LocalizedError, Equatable {
    case canceled
    case failed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .canceled: "The administrator password prompt was canceled."
        case .failed(let status): "macOS didn't grant the administrator authorization (OSStatus \(status))."
        }
    }
}

/// Obtains the modify-disk right from an administrator, for the helper to check. Blocks while macOS shows the
/// password prompt, so callers run it off the main thread.
enum Authorizer {
    /// The authorizations behind external forms handed out and not yet released. An external form is only valid while
    /// the process that made it still holds the authorization, so it must outlive the helper's check.
    private static let held = Mutex<[Data: HeldAuthorization]>([:])

    static func externalForm(prompt: String) throws -> Data {
        var created: AuthorizationRef?
        var status = AuthorizationCreate(nil, nil, [], &created)
        guard status == errAuthorizationSuccess, let ref = created else { throw AuthorizerError.failed(status) }

        status = copyModifyDiskRight(ref, prompt: prompt)
        guard status == errAuthorizationSuccess else {
            AuthorizationFree(ref, [])
            throw status == errAuthorizationCanceled ? AuthorizerError.canceled : AuthorizerError.failed(status)
        }

        var form = AuthorizationExternalForm()
        status = AuthorizationMakeExternalForm(ref, &form)
        guard status == errAuthorizationSuccess else {
            AuthorizationFree(ref, [])
            throw AuthorizerError.failed(status)
        }
        let data = withUnsafeBytes(of: &form.bytes) { Data($0) }
        held.withLock { $0[data] = HeldAuthorization(ref: ref) }
        return data
    }

    /// Asks for the right, letting macOS show its administrator prompt with `prompt` as the explanation.
    private static func copyModifyDiskRight(_ ref: AuthorizationRef, prompt: String) -> OSStatus {
        DrivewayIPC.AuthorizationRights.modifyDisk.withCString { rightName in
            kAuthorizationEnvironmentPrompt.withCString { promptName in
                prompt.withCString { promptText in
                    var right = AuthorizationItem(name: rightName, valueLength: 0, value: nil, flags: 0)
                    var promptItem = AuthorizationItem(
                        name: promptName, valueLength: strlen(promptText),
                        value: UnsafeMutableRawPointer(mutating: promptText), flags: 0)
                    return withUnsafeMutablePointer(to: &right) { rightPointer in
                        withUnsafeMutablePointer(to: &promptItem) { promptPointer in
                            var rights = Security.AuthorizationRights(count: 1, items: rightPointer)
                            var environment = AuthorizationEnvironment(count: 1, items: promptPointer)
                            return AuthorizationCopyRights(
                                ref, &rights, &environment, [.interactionAllowed, .extendRights, .preAuthorize], nil)
                        }
                    }
                }
            }
        }
    }

    /// Frees the authorization behind `externalForm` and destroys its rights, once the helper has replied.
    static func release(_ externalForm: Data) {
        guard let held = held.withLock({ $0.removeValue(forKey: externalForm) }) else { return }
        AuthorizationFree(held.ref, [.destroyRights])
    }
}

/// An `AuthorizationRef` is an opaque handle that may be used and freed from any thread.
private struct HeldAuthorization: @unchecked Sendable {
    let ref: AuthorizationRef
}

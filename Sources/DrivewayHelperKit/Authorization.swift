import DrivewayIPC
import Foundation
import Security

/// The authorization database entry for `app.driveway.helper.modify-disk`: the rule of
/// `kAuthorizationRuleAuthenticateAsAdmin` (an administrator's name and password), with `shared` false so the
/// credential is never shared with other processes, and a 60-second `timeout`.
///
/// The app asks for the password (pre-authorizes) and hands the authorization to the helper, which checks the right
/// again without a prompt. With `timeout` 0 the credential is spent by the app's own check, so the helper's check
/// always failed ("The administrator authorization wasn't accepted", live session 2026-10-31). 60 seconds covers
/// the trip to the helper, which checks before it waits for the disk. A credential still can't be reused for a later
/// operation: the app makes a new authorization for each request and frees it after the reply.
public enum ModifyDiskRight {
    public static let name = DrivewayIPC.AuthorizationRights.modifyDisk

    public static var definition: [String: Any] {
        [
            "class": "user",
            "group": "admin",
            "authenticate-user": true,
            "allow-root": false,
            "session-owner": false,
            "shared": false,
            "timeout": 60,
            "tries": 10000,
            "version": 0,
            "comment": "Used by Driveway's helper to format, repair or back up a drive.",
        ]
    }

    /// The keys that decide who passes, and how often they must authenticate.
    static let decidingKeys = ["class", "group", "authenticate-user", "allow-root", "session-owner", "shared", "timeout"]

    /// True when `existing` (from the authorization database) grants the right exactly as `definition` does.
    public static func isCurrent(_ existing: [String: Any]) -> Bool {
        decidingKeys.allSatisfy { key in
            guard let have = existing[key] as? NSObject, let want = definition[key] as? NSObject else { return false }
            return have.isEqual(want)
        }
    }
}

/// Adds the modify-disk right to the authorization database, or puts it back if it was changed.
/// Called by the root helper at launch; logs and carries on if it can't (requests needing the right then fail).
public func registerModifyDiskRight(log: (String) -> Void = { _ in }) {
    var existing: CFDictionary?
    if AuthorizationRightGet(ModifyDiskRight.name, &existing) == errAuthorizationSuccess,
       let current = existing as? [String: Any], ModifyDiskRight.isCurrent(current)
    {
        return
    }
    var ref: AuthorizationRef?
    guard AuthorizationCreate(nil, nil, [], &ref) == errAuthorizationSuccess, let ref else {
        log("Couldn't create an authorization to register \(ModifyDiskRight.name).")
        return
    }
    defer { AuthorizationFree(ref, []) }
    let status = AuthorizationRightSet(
        ref, ModifyDiskRight.name, ModifyDiskRight.definition as CFDictionary,
        "Driveway needs an administrator's password to change this drive." as CFString, nil, nil)
    if status != errAuthorizationSuccess {
        log("Couldn't register \(ModifyDiskRight.name): OSStatus \(status).")
    }
}

/// Checks an `AuthorizationExternalForm` sent by the app: rebuilds the reference and asks for the right
/// without user interaction. The app must already have obtained the right (it shows the password prompt).
public struct SystemAuthorizationVerifier: AuthorizationVerifying {
    public init() {}

    public func verify(_ externalForm: Data?, right: String) -> Bool {
        guard let externalForm, externalForm.count == Int(kAuthorizationExternalFormLength) else { return false }
        var form = AuthorizationExternalForm()
        _ = withUnsafeMutableBytes(of: &form.bytes) { externalForm.copyBytes(to: $0) }
        var ref: AuthorizationRef?
        guard AuthorizationCreateFromExternalForm(&form, &ref) == errAuthorizationSuccess, let ref else { return false }
        defer { AuthorizationFree(ref, []) }
        return right.withCString { name in
            var item = AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
            return withUnsafeMutablePointer(to: &item) { items in
                var rights = Security.AuthorizationRights(count: 1, items: items)
                return AuthorizationCopyRights(ref, &rights, nil, [.extendRights], nil) == errAuthorizationSuccess
            }
        }
    }
}

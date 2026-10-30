import Foundation

/// Exported by the helper. `request` is a JSON-encoded `HelperRequest`; the reply is a JSON-encoded
/// `HelperResponse`. `authorization` is an `AuthorizationExternalForm` for requests that need one.
@objc public protocol DrivewayHelperXPC {
    func perform(_ request: Data, authorization: Data?, reply: @escaping (Data) -> Void)
}

/// Exported by clients so the helper can push JSON-encoded `VolumeEvent`s.
@objc public protocol DrivewayEventsXPC {
    func volumeEvent(_ event: Data)
}

public enum MachServices {
    public static let helper = "app.driveway.helper"
}

public enum AuthorizationRights {
    public static let modifyDisk = "app.driveway.helper.modify-disk"
}

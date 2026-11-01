import DrivewayCore
import DrivewayHelperKit
import DrivewayIPC
import Foundation
import Testing

// MARK: - Asking the helper

@Test func helperSaysWhetherItHasFullDiskAccessWithoutAuthorization() async {
    let h = makeHarness(disks: [])
    #expect(!HelperRequest.helperPermissions.requiresAuthorization)
    #expect(await h.service.handle(.helperPermissions, authorization: nil) == .permissions(HelperPermissions(fullDiskAccess: nil)))
    h.inventory.setFullDiskAccess(false)
    #expect(await h.service.handle(.helperPermissions, authorization: nil) == .permissions(HelperPermissions(fullDiskAccess: false)))
    h.inventory.setFullDiskAccess(true)
    #expect(await h.service.handle(.helperPermissions, authorization: nil) == .permissions(HelperPermissions(fullDiskAccess: true)))
}

@Test func permissionsJSONToleratesMissingFields() throws {
    #expect(try JSONDecoder().decode(HelperPermissions.self, from: Data("{}".utf8)) == HelperPermissions(fullDiskAccess: nil))
    for value in [HelperPermissions(fullDiskAccess: true), HelperPermissions(fullDiskAccess: false), HelperPermissions(fullDiskAccess: nil)] {
        let response = HelperResponse.permissions(value)
        #expect(try JSONDecoder().decode(HelperResponse.self, from: JSONEncoder().encode(response)) == response)
    }
    let request = HelperRequest.helperPermissions
    #expect(try JSONDecoder().decode(HelperRequest.self, from: JSONEncoder().encode(request)) == request)
}

@Test func fullDiskAccessProbeOpensTheFileReadOnly() throws {
    #expect(HelperEnvironment.fullDiskAccess(probePath: "/nonexistent-\(UUID().uuidString)/TCC.db") == nil)
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("tcc-probe-\(UUID().uuidString)")
    try Data("x".utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(HelperEnvironment.fullDiskAccess(probePath: url.path) == true)
}

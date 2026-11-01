import DrivewayHelperKit
import Foundation
import Testing

@Test func modifyDiskRightDefinition() {
    let d = ModifyDiskRight.definition
    #expect(d["timeout"] as? Int == 60)
    #expect(d["shared"] as? Bool == false)
    #expect(d["group"] as? String == "admin")
    #expect(ModifyDiskRight.isCurrent(d))
    // A looser stored rule is put back.
    var shared = d
    shared["shared"] = true
    #expect(!ModifyDiskRight.isCurrent(shared))
    var cached = d
    cached["timeout"] = 300
    #expect(!ModifyDiskRight.isCurrent(cached))
    #expect(!ModifyDiskRight.isCurrent(["rule": "allow"]))
}

@Test func verifierRejectsMalformedForms() {
    let v = SystemAuthorizationVerifier()
    #expect(!v.verify(nil, right: ModifyDiskRight.name))
    #expect(!v.verify(Data(count: 5), right: ModifyDiskRight.name))
    // Well-formed length, but no such authorization.
    #expect(!v.verify(Data(count: 32), right: ModifyDiskRight.name))
}

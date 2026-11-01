import DrivewayCore
import DrivewayHelperKit
import DrivewayIPC
import Foundation
import Testing

@Test func reevaluationTriggerFiresWhenFullDiskAccessIsGranted() {
    let user = ConsoleUser(uid: 501, gid: 20)
    var t = ReevaluationTrigger(user: user, features: allReady, fullDiskAccess: false)
    func update(_ access: Bool?) -> Bool { t.update(user: user, features: allReady, fullDiskAccess: access) }
    #expect(!update(false))
    #expect(!update(nil))  // the probe told nothing
    #expect(update(true))
    #expect(!update(true))
    // Never known to be missing: nothing was left to macOS for it.
    var fresh = ReevaluationTrigger(user: user, features: allReady)
    let fired = fresh.update(user: user, features: allReady, fullDiskAccess: true)
    #expect(!fired)
}

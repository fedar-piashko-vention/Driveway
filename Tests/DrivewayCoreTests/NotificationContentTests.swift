import Foundation
import Testing

@testable import DrivewayCore

@Test func dirtyNotificationUsesSpecCopy() {
    let n = NotificationContent.readOnly(label: "WIN_DATA", bsdName: "disk5s1", health: .dirty, error: nil)
    #expect(n.title == "Driveway")
    #expect(n.body == "WIN_DATA was mounted read-only because Windows didn't shut it down cleanly — click to fix")
    #expect(n.openURL == URL(string: "driveway://volume/disk5s1"))
}

@Test func hibernatedNotificationExplainsFastStartup() {
    let n = NotificationContent.readOnly(label: "WIN_DATA", bsdName: "disk5s1", health: .hibernated, error: nil)
    #expect(n.title == "Driveway")
    #expect(
        n.body
            == "WIN_DATA was mounted read-only because Windows is hibernating (Fast Startup). Shut Windows down fully, then plug the drive in again."
    )
    #expect(n.openURL == URL(string: "driveway://volume/disk5s1"))
}

@Test func backedOffNotification() {
    let n = NotificationContent.backedOff(label: "BACKUP", driver: "Tuxera NTFS")
    #expect(n.title == "Driveway")
    #expect(n.body == "BACKUP was mounted by Tuxera NTFS, so Driveway left it alone.")
    #expect(n.openURL == nil)
}

@Test func readOnlyWithErrorOnOtherHealthExplainsTheError() {
    for health in [VolumeHealth.clean, .unknown] {
        let n = NotificationContent.readOnly(label: "USB1", bsdName: "disk6s2", health: health, error: "ntfs-3g not found")
        #expect(n.title == "Driveway")
        #expect(
            n.body
                == "USB1 was mounted read-only because Driveway couldn't mount it read/write: ntfs-3g not found — click to fix"
        )
        #expect(n.openURL == URL(string: "driveway://volume/disk6s2"))
    }
}

@Test func dirtyAndHibernatedIgnoreAnyErrorText() {
    let dirty = NotificationContent.readOnly(label: "A", bsdName: "disk2s1", health: .dirty, error: "boom")
    #expect(dirty.body == "A was mounted read-only because Windows didn't shut it down cleanly — click to fix")
    let hib = NotificationContent.readOnly(label: "A", bsdName: "disk2s1", health: .hibernated, error: "boom")
    #expect(hib.body.contains("hibernating (Fast Startup)"))
}

@Test func mountFailedNotification() {
    let n = NotificationContent.mountFailed(label: "WIN_DATA", message: "device busy")
    #expect(n.title == "Driveway")
    #expect(n.body == "Driveway couldn't mount WIN_DATA: device busy")
    #expect(n.openURL == nil)
}

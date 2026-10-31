import Foundation
import Testing
import DrivewayCore

struct RepairActionsTests {
    @Test func actionsPerFilesystem() {
        #expect(VolumeList.repairActions(for: .ntfs) == [.check, .backupFirst, .repair])
        #expect(VolumeList.repairActions(for: .ext4) == [.check, .repair, .repairForce])
        #expect(VolumeList.repairActions(for: .exfat) == [.check, .repair])
        #expect(VolumeList.repairActions(for: .other) == [])
        #expect(VolumeList.repairActions(for: .ext2) == [.check, .repair, .repairForce])
        #expect(VolumeList.repairActions(for: .ext3) == [.check, .repair, .repairForce])
        #expect(VolumeList.repairActions(for: .fat32) == [.check, .repair])
        #expect(VolumeList.repairActions(for: .fat16) == [.check, .repair])
    }

    @Test func ntfsNoteIsSpecCopy() {
        #expect(
            VolumeList.repairNote(for: .ntfs)
                == "This fixes common issues (unclean eject, journal), not deep damage. For real damage, connect the drive to Windows and run chkdsk /f."
        )
        #expect(VolumeList.repairNote(for: .exfat) == nil)
        #expect(VolumeList.repairNote(for: .ext4) == nil)
        #expect(VolumeList.repairNote(for: .other) == nil)
        #expect(Copy.backUpFirst == "Back up first")
    }

    @Test func backupFileNameUsesLabelAndLocalDate() throws {
        let zone = try #require(TimeZone(identifier: "Pacific/Auckland"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        // 02:30 on the 7th in Auckland (UTC+13) is still the 6th in UTC and in Los Angeles.
        let date = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 7, hour: 2, minute: 30)))
        #expect(VolumeList.backupFileName(label: "My Drive", date: date, timeZone: zone) == "My Drive-2026-03-07.img")
        let utc = try #require(TimeZone(identifier: "UTC"))
        #expect(VolumeList.backupFileName(label: "My Drive", date: date, timeZone: utc) == "My Drive-2026-03-06.img")
        let la = try #require(TimeZone(identifier: "America/Los_Angeles"))
        #expect(VolumeList.backupFileName(label: "X", date: date, timeZone: la) == "X-2026-03-06.img")
    }

    @Test func backupFileNameKeepsPathSeparatorsOutOfTheLabel() throws {
        let utc = try #require(TimeZone(identifier: "UTC"))
        let date = Date(timeIntervalSince1970: 0)
        #expect(VolumeList.backupFileName(label: "a/b:c", date: date, timeZone: utc) == "a-b-c-1970-01-01.img")
        #expect(VolumeList.backupFileName(label: "", date: date, timeZone: utc) == "Drive-1970-01-01.img")
    }
}

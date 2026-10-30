import Testing
import Foundation
import DrivewayCore

struct VolumeCodableTests {
    @Test func volumeRoundTripsThroughJSON() throws {
        let volume = Volume(
            bsdName: "disk4s1", wholeDisk: "disk4", label: "Backup", filesystem: .ntfs,
            capacityBytes: 1_000_000_000_000, usedBytes: 250_000_000_000, mountPoint: "/Volumes/Backup",
            access: .readOnly, health: .clean, mountedBy: .otherDriver("Tuxera NTFS"),
            deviceModel: "Portable SSD", settingsKey: "UUID-1234", lastError: nil, backend: .kernel
        )
        let data = try JSONEncoder().encode(volume)
        let decoded = try JSONDecoder().decode(Volume.self, from: data)
        #expect(decoded == volume)
        #expect(decoded.backend == .kernel)
        #expect(decoded.mountedBy == .otherDriver("Tuxera NTFS"))
    }
}

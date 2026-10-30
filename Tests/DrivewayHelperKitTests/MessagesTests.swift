import DrivewayCore
import DrivewayIPC
import Foundation
import Testing

private let sampleFormat = FormatRequest(
    filesystem: .ntfs, label: "NEW", scheme: .mbr, target: .wholeDisk("disk4"), confirmation: "BACKUP")

private let sampleVolume = Volume(
    bsdName: "disk4s1", wholeDisk: "disk4", label: "BACKUP", filesystem: .ntfs, capacityBytes: 10,
    usedBytes: 5, mountPoint: "/Volumes/BACKUP", access: .readWrite, health: .clean, mountedBy: .driveway,
    deviceModel: "SSD", settingsKey: "K", lastError: nil, backend: .fskit)

private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
    try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
}

@Test func requestRoundTripAndAuthTable() throws {
    let all: [HelperRequest] = [
        .listVolumes, .mount("disk4s1"), .unmount("disk4s1"), .eject("disk4s1"), .fixAndMount("disk4s1"),
        .check("disk4s1"), .repair("disk4s1", force: true), .backup("disk4s1", imagePath: "/Users/x/b.img"),
        .format(sampleFormat), .getSettings, .setSettings(DrivewaySettings(alwaysReadOnly: ["K"])),
        .helperVersion, .backendStatus,
    ]
    for r in all { #expect(try roundTrip(r) == r) }

    let authorized = all.filter(\.requiresAuthorization)
    #expect(authorized == [
        .fixAndMount("disk4s1"), .repair("disk4s1", force: true), .backup("disk4s1", imagePath: "/Users/x/b.img"),
        .format(sampleFormat),
    ])
    #expect(HelperRequest.repair("disk4s1", force: false).requiresAuthorization)
    #expect(!HelperRequest.mount("disk4s1").requiresAuthorization)
}

@Test func responsesAndEventsRoundTrip() throws {
    let responses: [HelperResponse] = [
        .volumes([sampleVolume]), .volume(sampleVolume), .volume(nil),
        .report(CheckReport(filesystem: .ext4, mode: .repairForce, succeeded: false, summary: "s", rawOutput: "r")),
        .settings(DrivewaySettings()), .version("1.2.3"), .backend(.needsApproval(.fskit)), .ok,
        .error(.protectedDisk), .error(.notAuthorized), .error(.unknownVolume), .error(.toolMissing("/x")),
        .error(.commandFailed("boom")), .error(.validation(.labelTooLong(max: 32))),
    ]
    for r in responses { #expect(try roundTrip(r) == r) }

    let events: [VolumeEvent] = [
        .mounted(sampleVolume), .mountedReadOnly(sampleVolume, reason: .dirty),
        .mountedReadOnly(sampleVolume, reason: .hibernated), .mountedReadOnly(sampleVolume, reason: .error("x")),
        .backedOff(sampleVolume, driver: "Tuxera NTFS"), .mountFailed(sampleVolume, message: "m"),
        .removed(bsdName: "disk4s1"),
    ]
    for e in events { #expect(try roundTrip(e) == e) }
}

@Test func identifiersAndVersion() {
    #expect(MachServices.helper == "app.driveway.helper")
    #expect(AuthorizationRights.modifyDisk == "app.driveway.helper.modify-disk")
    #expect(!helperProtocolVersion.isEmpty)
}

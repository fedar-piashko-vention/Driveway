import DrivewayCore
import DrivewayHelperKit
import Foundation
import Testing

private func tempURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("driveway-tests-\(UUID().uuidString)")
        .appendingPathComponent("nested/settings.json")
}

@Test func settingsStoreDefaultsToSystemPath() {
    #expect(SettingsStore().url.path == "/Library/Application Support/Driveway/settings.json")
}

@Test func settingsStoreLoadsDefaultsWhenMissingOrCorrupt() throws {
    let url = tempURL()
    let store = SettingsStore(url: url)
    #expect(store.load() == DrivewaySettings())

    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("not json".utf8).write(to: url)
    #expect(store.load() == DrivewaySettings())
}

@Test func settingsStoreSavesAtomicallyWithMode0644() throws {
    let url = tempURL()
    let store = SettingsStore(url: url)
    let s = DrivewaySettings(autoMountNTFS: false, alwaysReadOnly: ["K"], allowDiskImagesForTesting: true, fskitFailedOnOSBuild: "24G84")
    try store.save(s)  // creates the missing directories
    #expect(store.load() == s)

    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o644)

    // Overwrite keeps the mode.
    try store.save(DrivewaySettings())
    #expect(store.load() == DrivewaySettings())
    let again = try FileManager.default.attributesOfItem(atPath: url.path)
    #expect((again[.posixPermissions] as? NSNumber)?.intValue == 0o644)
}

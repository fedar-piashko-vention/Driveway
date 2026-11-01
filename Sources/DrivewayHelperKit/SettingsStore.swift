import DrivewayCore
import Foundation

public protocol SettingsStoring: Sendable {
    func load() -> DrivewaySettings
    func save(_ s: DrivewaySettings) throws
}

/// Settings as JSON, written by the root helper and readable by everyone (mode 0644).
public struct SettingsStore: SettingsStoring {
    public static let defaultURL = URL(fileURLWithPath: "/Library/Application Support/Driveway/settings.json")

    public let url: URL

    public init(url: URL = SettingsStore.defaultURL) {
        self.url = url
    }

    /// Defaults when the file is missing or can't be decoded. Never throws.
    public func load() -> DrivewaySettings {
        guard let data = try? Data(contentsOf: url),
              let settings = try? JSONDecoder().decode(DrivewaySettings.self, from: data)
        else { return DrivewaySettings() }
        return settings
    }

    /// Creates the directory if needed, writes atomically, then sets mode 0644.
    public func save(_ s: DrivewaySettings) throws {
        let fm = FileManager.default
        try fm.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(s).write(to: url, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
    }
}

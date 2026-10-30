import Testing
import Foundation
@testable import DrivewayCore

struct ModelsTests {
    @Test func semanticVersionParsingAndOrder() {
        #expect(SemanticVersion("5.4") == SemanticVersion("5.4.0"))
        #expect(SemanticVersion("5.3.2")! < SemanticVersion("5.4.0")!)
        #expect(SemanticVersion("banana") == nil)
    }

    private func description(volumeUUID: String?, mediaUUID: String?) -> DiskDescription {
        DiskDescription(
            bsdName: "disk4s1", wholeDisk: "disk4", isWholeMedia: false, isInternal: false, isDiskImage: false,
            volumeKind: nil, volumeType: nil, contentType: nil, volumeName: nil,
            volumeUUID: volumeUUID, mediaUUID: mediaUUID,
            sizeBytes: 0, deviceModel: "", volumePath: nil
        )
    }

    @Test func settingsKeyPrefersVolumeUUID() {
        #expect(description(volumeUUID: "A", mediaUUID: "B").settingsKey == "A")
        #expect(description(volumeUUID: nil, mediaUUID: "B").settingsKey == "B")
        #expect(description(volumeUUID: nil, mediaUUID: nil).settingsKey == "disk4s1")
    }
}

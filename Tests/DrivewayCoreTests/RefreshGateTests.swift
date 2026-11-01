import Testing
import DrivewayCore

struct RefreshGateTests {
    @Test func listIsKeptWhenNothingHappenedMeanwhile() {
        let gate = RefreshGate()
        let token = gate.beginRefresh()
        #expect(gate.acceptsVolumes(from: token))
        #expect(gate.acceptsSettings(from: token))
    }

    @Test func eventDuringRefreshMakesTheListStale() {
        var gate = RefreshGate()
        let token = gate.beginRefresh()
        gate.eventApplied()
        #expect(!gate.acceptsVolumes(from: token))
        #expect(gate.acceptsSettings(from: token))
        #expect(gate.acceptsVolumes(from: gate.beginRefresh()))
    }

    @Test func settingsAreStaleWhileAWriteIsPendingOrAfterALocalChange() {
        var gate = RefreshGate()
        let before = gate.beginRefresh()
        gate.settingsWriteStarted()
        #expect(!gate.acceptsSettings(from: before))
        let during = gate.beginRefresh()
        #expect(!gate.acceptsSettings(from: during))
        gate.settingsWriteFinished()
        #expect(!gate.acceptsSettings(from: before))
        #expect(!gate.acceptsSettings(from: during))
        #expect(gate.acceptsSettings(from: gate.beginRefresh()))
        #expect(gate.acceptsVolumes(from: before))
    }

    @Test func overlappingWritesKeepSettingsStaleUntilTheLastFinishes() {
        var gate = RefreshGate()
        gate.settingsWriteStarted()
        gate.settingsWriteStarted()
        gate.settingsWriteFinished()
        #expect(!gate.acceptsSettings(from: gate.beginRefresh()))
        gate.settingsWriteFinished()
        #expect(gate.acceptsSettings(from: gate.beginRefresh()))
    }
}

import Foundation
import Testing
@testable import Sotto

struct SyncSinkRegistryTests {
    private func freshSuite() -> UserDefaults {
        UserDefaults(suiteName: "sink-registry-\(UUID().uuidString)")!
    }

    @Test func iCloudSinkPresentWhenEnabled() {
        let settings = SettingsStore(defaults: freshSuite())   // default on
        let sinks = SyncSinkRegistry.activeSinks(settings)
        #expect(sinks.count == 1)
        #expect(sinks.first is ICloudSyncSink)
    }

    @Test func noSinksWhenDisabled() {
        let settings = SettingsStore(defaults: freshSuite())
        settings.iCloudBackupEnabled = false
        #expect(SyncSinkRegistry.activeSinks(settings).isEmpty)
    }
}

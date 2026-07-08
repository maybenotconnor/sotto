import Foundation
import Testing
@testable import Sotto

struct SettingsStoreICloudTests {
    private func freshSuite() -> UserDefaults {
        UserDefaults(suiteName: "settings-icloud-\(UUID().uuidString)")!
    }

    @Test func iCloudBackupDefaultsOnWhenUnset() {
        let settings = SettingsStore(defaults: freshSuite())
        #expect(settings.iCloudBackupEnabled == true)   // opt-out: default on
    }

    @Test func iCloudBackupRoundTripsFalse() {
        let settings = SettingsStore(defaults: freshSuite())
        settings.iCloudBackupEnabled = false
        #expect(settings.iCloudBackupEnabled == false)
    }
}

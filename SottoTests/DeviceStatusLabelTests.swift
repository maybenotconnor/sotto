import Testing
@testable import Sotto

struct DeviceStatusLabelTests {
    @Test func idleAndInSessionDisconnectedAreDistinct() {
        #expect(SettingsView.deviceStatusLabel(for: nil) == "Connects when listening")
        #expect(SettingsView.deviceStatusLabel(for: .disconnected) == "Not connected")
    }

    @Test func sessionStatesMapToLabels() {
        #expect(SettingsView.deviceStatusLabel(for: .connecting) == "Connecting…")
        #expect(SettingsView.deviceStatusLabel(for: .connected) == "Connected")
        #expect(SettingsView.deviceStatusLabel(for: .streaming) == "Streaming")
        #expect(SettingsView.deviceStatusLabel(for: .unavailable(.poweredOff)) == "Bluetooth is off")
        #expect(SettingsView.deviceStatusLabel(for: .unavailable(.unauthorized)) == "Bluetooth permission needed")
        #expect(SettingsView.deviceStatusLabel(for: .unavailable(.unsupported)) == "Bluetooth unavailable")
    }
}

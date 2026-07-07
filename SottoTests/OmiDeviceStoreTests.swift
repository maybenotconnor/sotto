import Foundation
import Testing
@testable import Sotto

struct OmiDeviceStoreTests {
    @Test func freshDefaultsHasNoPairedDevice() {
        let suite = UserDefaults(suiteName: "omi-device-store-fresh-\(UUID().uuidString)")!
        let store = OmiDeviceStore(defaults: suite)
        #expect(store.device == nil)
    }

    @Test func pairRoundTripsTheDevice() {
        let suite = UserDefaults(suiteName: "omi-device-store-pair-\(UUID().uuidString)")!
        let store = OmiDeviceStore(defaults: suite)
        let device = PairedOmiDevice(id: UUID(), name: "Omi DevKit 2")

        store.pair(device)

        #expect(store.device == device)
        // Round-trips through a SECOND store instance over the same defaults too — proves
        // it's really persisted (JSON in UserDefaults), not just an in-memory cache.
        #expect(OmiDeviceStore(defaults: suite).device == device)
    }

    @Test func forgetClearsThePairedDevice() {
        let suite = UserDefaults(suiteName: "omi-device-store-forget-\(UUID().uuidString)")!
        let store = OmiDeviceStore(defaults: suite)
        store.pair(PairedOmiDevice(id: UUID(), name: "Omi DevKit 2"))
        #expect(store.device != nil)

        store.forget()

        #expect(store.device == nil)
    }

    @Test func pairingASecondDeviceReplacesTheFirst() {
        // Spec "Selection model": auto-prefer ONE device — pairing a new one replaces
        // whatever was paired before, it never accumulates a list.
        let suite = UserDefaults(suiteName: "omi-device-store-replace-\(UUID().uuidString)")!
        let store = OmiDeviceStore(defaults: suite)
        store.pair(PairedOmiDevice(id: UUID(), name: "First"))
        let second = PairedOmiDevice(id: UUID(), name: "Second")

        store.pair(second)

        #expect(store.device == second)
    }
}

import Foundation
import Testing
@testable import Sotto

struct PairedDeviceStoreTests {
    @Test func freshDefaultsHasNoPairedDevice() {
        let suite = UserDefaults(suiteName: "paired-device-store-fresh-\(UUID().uuidString)")!
        let store = PairedDeviceStore(defaults: suite)
        #expect(store.device == nil)
    }

    @Test func pairRoundTripsTheDevice() {
        let suite = UserDefaults(suiteName: "paired-device-store-pair-\(UUID().uuidString)")!
        let store = PairedDeviceStore(defaults: suite)
        let device = PairedDevice(id: UUID(), name: "Omi DevKit 2", kind: .omi)

        store.pair(device)

        #expect(store.device == device)
        // Round-trips through a SECOND store instance over the same defaults too — proves
        // it's really persisted (JSON in UserDefaults), not just an in-memory cache.
        #expect(PairedDeviceStore(defaults: suite).device == device)
    }

    @Test func forgetClearsThePairedDevice() {
        let suite = UserDefaults(suiteName: "paired-device-store-forget-\(UUID().uuidString)")!
        let store = PairedDeviceStore(defaults: suite)
        store.pair(PairedDevice(id: UUID(), name: "Omi DevKit 2", kind: .omi))
        #expect(store.device != nil)

        store.forget()

        #expect(store.device == nil)
    }

    @Test func legacyRecordWithoutKindDecodesAsOmiPairing() throws {
        // Pre-generalization records (struct PairedOmiDevice { id, name }) live under
        // the SAME UserDefaults key and must decode as an Omi pairing — this is the
        // refactor's only migration point.
        let suite = UserDefaults(suiteName: "paired-device-store-legacy-\(UUID().uuidString)")!
        let id = UUID(uuidString: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F")!
        let legacy = Data(#"{"id":"E621E1F8-C36C-495A-93FC-0C247A3E6E5F","name":"Omi DevKit 2"}"#.utf8)
        suite.set(legacy, forKey: "pairedOmiDevice")

        let store = PairedDeviceStore(defaults: suite)

        #expect(store.device == PairedDevice(id: id, name: "Omi DevKit 2", kind: .omi))
    }

    @Test func pairingASecondDeviceReplacesTheFirst() {
        // Spec "Selection model": auto-prefer ONE device — pairing a new one replaces
        // whatever was paired before, it never accumulates a list.
        let suite = UserDefaults(suiteName: "paired-device-store-replace-\(UUID().uuidString)")!
        let store = PairedDeviceStore(defaults: suite)
        store.pair(PairedDevice(id: UUID(), name: "First", kind: .omi))
        let second = PairedDevice(id: UUID(), name: "Second", kind: .omi)

        store.pair(second)

        #expect(store.device == second)
    }
}

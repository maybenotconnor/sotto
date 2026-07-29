import Foundation
import Testing
@testable import Sotto

struct SummaryBackendTests {
    private func store() -> SettingsStore {
        SettingsStore(defaults: UserDefaults(suiteName: "SummaryBackendTests-\(UUID().uuidString)")!)
    }

    @Test func defaultsToOnDevice() {
        #expect(store().summaryBackend == .onDevice)
    }

    @Test func roundTripsBackendSelection() {
        let settings = store()
        settings.summaryBackend = .openRouter
        #expect(settings.summaryBackend == .openRouter)
    }

    @Test func corruptRawValueFallsBackToOnDevice() {
        let settings = store()
        settings.defaults.set("not-a-backend", forKey: "summaryBackend")
        #expect(settings.summaryBackend == .onDevice)
    }

    @Test func modelResolvesOverrideThenPresetDefault() {
        let settings = store()
        #expect(settings.summaryModel(for: .openAI) == "gpt-5-mini")
        settings.setSummaryModel("gpt-5.2", for: .openAI)
        #expect(settings.summaryModel(for: .openAI) == "gpt-5.2")
        #expect(settings.summaryModelOverride(for: .openAI) == "gpt-5.2")
        // Overrides are per-provider: anthropic still resolves its own default.
        #expect(settings.summaryModel(for: .anthropic) == "claude-haiku-4-5")
        settings.setSummaryModel(nil, for: .openAI)
        #expect(settings.summaryModel(for: .openAI) == "gpt-5-mini")
    }

    @Test func customHasNoDefaultModel() {
        let settings = store()
        #expect(settings.summaryModel(for: .custom) == nil)
        settings.setSummaryModel("llama3", for: .custom)
        #expect(settings.summaryModel(for: .custom) == "llama3")
    }

    @Test func presetDataIsConsistent() {
        for backend in SummaryBackend.allCases where backend != .onDevice && backend != .custom {
            #expect(backend.presetEndpoint != nil)
            #expect(backend.defaultModel != nil)
            #expect(backend.keychainKey != nil)
        }
        #expect(SummaryBackend.onDevice.keychainKey == nil)
        #expect(SummaryBackend.custom.keychainKey == "summaryAPIKey.custom")
        #expect(SummaryBackend.anthropic.presetEndpoint?.absoluteString
            == "https://api.anthropic.com/v1/chat/completions")
    }
}

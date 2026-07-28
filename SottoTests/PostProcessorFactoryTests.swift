import Foundation
import Testing
@testable import Sotto

/// Deterministic fake: returns a canned result or throws.
private struct FakeProcessor: PostProcessor {
    let result: PostProcessingResult?
    func process(transcript: TranscriptionResult, audio: URL?) async throws -> PostProcessingResult {
        guard let result else { throw CloudSummaryError.badResponse(500) }
        return result
    }
}

struct PostProcessorFactoryTests {
    private func settings() -> SettingsStore {
        SettingsStore(defaults: UserDefaults(suiteName: "FactoryTests-\(UUID().uuidString)")!)
    }

    private let transcript = TranscriptionResult(
        text: Array(repeating: "word", count: 60).joined(separator: " "),
        segments: [], duration: 60, backend: .speechAnalyzer)

    private let notes = PostProcessingResult(
        title: "T", summary: "S", actionItems: nil, custom: nil, truncated: false)

    // MARK: FallbackPostProcessor

    @Test func primarySuccessSkipsFallback() async throws {
        let wrapper = FallbackPostProcessor(
            primary: FakeProcessor(result: notes),
            fallback: FakeProcessor(result: nil))   // would throw if called
        let result = try await wrapper.process(transcript: transcript, audio: nil)
        #expect(result.title == "T")
    }

    @Test func primaryFailureRunsFallback() async throws {
        let fallbackNotes = PostProcessingResult(
            title: "FB", summary: "fallback", actionItems: nil, custom: nil, truncated: true)
        let wrapper = FallbackPostProcessor(
            primary: FakeProcessor(result: nil),
            fallback: FakeProcessor(result: fallbackNotes))
        let result = try await wrapper.process(transcript: transcript, audio: nil)
        #expect(result.title == "FB")
    }

    @Test func bothFailingThrows() async {
        let wrapper = FallbackPostProcessor(
            primary: FakeProcessor(result: nil), fallback: FakeProcessor(result: nil))
        await #expect(throws: CloudSummaryError.self) {
            _ = try await wrapper.process(transcript: transcript, audio: nil)
        }
    }

    @Test func noFallbackRethrowsPrimaryError() async {
        let wrapper = FallbackPostProcessor(primary: FakeProcessor(result: nil), fallback: nil)
        await #expect(throws: CloudSummaryError.self) {
            _ = try await wrapper.process(transcript: transcript, audio: nil)
        }
    }

    // MARK: factory composition rules

    @Test func lowPowerModeReturnsNil() {
        let processor = PostProcessorFactory.make(
            settings: settings(), keychain: KeychainStore(service: "f-\(UUID().uuidString)"),
            lowPowerMode: true, onDeviceAvailable: true)
        #expect(processor == nil)
    }

    @Test func onDeviceOnlyWhenCloudUnconfigured() {
        let processor = PostProcessorFactory.make(
            settings: settings(), keychain: KeychainStore(service: "f-\(UUID().uuidString)"),
            lowPowerMode: false, onDeviceAvailable: true)
        #expect(processor is FoundationModelsPostProcessor)
    }

    @Test func nothingAvailableReturnsNil() {
        let processor = PostProcessorFactory.make(
            settings: settings(), keychain: KeychainStore(service: "f-\(UUID().uuidString)"),
            lowPowerMode: false, onDeviceAvailable: false)
        #expect(processor == nil)
    }

    @Test func configuredCloudWrapsInFallback() {
        let keychain = KeychainStore(service: "f-\(UUID().uuidString)")
        defer { keychain.delete("summaryAPIKey.openai") }
        keychain.set("sk", for: "summaryAPIKey.openai")
        let s = settings()
        s.summaryBackend = .openAI
        let processor = PostProcessorFactory.make(
            settings: s, keychain: keychain, lowPowerMode: false, onDeviceAvailable: false)
        let wrapper = try? #require(processor as? FallbackPostProcessor)
        #expect(wrapper?.primary is ChatCompletionsPostProcessor)
        #expect(wrapper?.fallback == nil)   // no Apple Intelligence → cloud only
    }

    @Test func configuredCloudKeepsOnDeviceFallback() {
        let keychain = KeychainStore(service: "f-\(UUID().uuidString)")
        defer { keychain.delete("summaryAPIKey.openai") }
        keychain.set("sk", for: "summaryAPIKey.openai")
        let s = settings()
        s.summaryBackend = .openAI
        let processor = PostProcessorFactory.make(
            settings: s, keychain: keychain, lowPowerMode: false, onDeviceAvailable: true)
        let wrapper = try? #require(processor as? FallbackPostProcessor)
        #expect(wrapper?.fallback is FoundationModelsPostProcessor)
    }

    @Test func cloudSelectedWithoutKeyFallsBackSilently() {
        let s = settings()
        s.summaryBackend = .anthropic   // preference set, no key pasted
        let processor = PostProcessorFactory.make(
            settings: s, keychain: KeychainStore(service: "f-\(UUID().uuidString)"),
            lowPowerMode: false, onDeviceAvailable: true)
        #expect(processor is FoundationModelsPostProcessor)
    }

    // MARK: availability helper

    @Test func summariesAvailableReflectsEitherPath() {
        let s = settings()
        let keychain = KeychainStore(service: "f-\(UUID().uuidString)")
        #expect(!PostProcessorFactory.summariesAvailable(
            settings: s, keychain: keychain, onDeviceAvailable: false))
        #expect(PostProcessorFactory.summariesAvailable(
            settings: s, keychain: keychain, onDeviceAvailable: true))
        s.summaryBackend = .openAI
        keychain.set("sk", for: "summaryAPIKey.openai")
        defer { keychain.delete("summaryAPIKey.openai") }
        #expect(PostProcessorFactory.summariesAvailable(
            settings: s, keychain: keychain, onDeviceAvailable: false))
    }
}

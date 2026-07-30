import Foundation
import Synchronization
import Testing
@testable import Sotto

struct ChatCompletionsPostProcessorTests {
    private func mockedSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func settings() -> SettingsStore {
        SettingsStore(defaults: UserDefaults(suiteName: "CCTests-\(UUID().uuidString)")!)
    }

    private let openAIConfig = ChatCompletionsConfig(
        endpoint: URL(string: "https://api.openai.com/v1/chat/completions")!,
        model: "gpt-5-mini", keychainKey: "summaryAPIKey.openai")

    private func okBody(content: String) -> Data {
        let json: [String: Any] = ["choices": [["message": ["role": "assistant", "content": content]]]]
        return try! JSONSerialization.data(withJSONObject: json)
    }

    private func longTranscript(words: Int = 60) -> TranscriptionResult {
        TranscriptionResult(
            text: Array(repeating: "word", count: words).joined(separator: " "),
            segments: [], duration: 60, backend: .speechAnalyzer)
    }

    // MARK: config resolution

    @Test func resolveReturnsNilWithoutKey() {
        let keychain = KeychainStore(service: "cc-test-\(UUID().uuidString)")
        let s = settings()
        s.summaryBackend = .openAI
        #expect(ChatCompletionsConfig.resolve(settings: s, keychain: keychain) == nil)
    }

    @Test func resolveBuildsPresetConfig() {
        let keychain = KeychainStore(service: "cc-test-\(UUID().uuidString)")
        defer { keychain.delete("summaryAPIKey.openai") }
        keychain.set("sk-live", for: "summaryAPIKey.openai")
        let s = settings()
        s.summaryBackend = .openAI
        let config = ChatCompletionsConfig.resolve(settings: s, keychain: keychain)
        #expect(config == openAIConfig)
    }

    @Test func resolveCustomAppendsChatCompletionsPath() {
        let keychain = KeychainStore(service: "cc-test-\(UUID().uuidString)")
        defer { keychain.delete("summaryAPIKey.custom") }
        keychain.set("k", for: "summaryAPIKey.custom")
        let s = settings()
        s.summaryBackend = .custom
        s.summaryCustomBaseURL = "http://localhost:11434/v1"
        s.setSummaryModel("llama3", for: .custom)
        let config = ChatCompletionsConfig.resolve(settings: s, keychain: keychain)
        #expect(config?.endpoint.absoluteString == "http://localhost:11434/v1/chat/completions")
        // A pasted full URL isn't double-appended.
        s.summaryCustomBaseURL = "http://localhost:11434/v1/chat/completions"
        #expect(ChatCompletionsConfig.resolve(settings: s, keychain: keychain)?.endpoint.absoluteString
            == "http://localhost:11434/v1/chat/completions")
        // Custom without a model is unconfigured.
        s.setSummaryModel(nil, for: .custom)
        #expect(ChatCompletionsConfig.resolve(settings: s, keychain: keychain) == nil)
    }

    @Test func customEndpointValidatesAndNormalizes() {
        typealias Config = ChatCompletionsConfig
        // Trailing slashes never double-append the path.
        #expect(Config.customEndpoint(fromBase: "http://localhost:11434/v1/")?.absoluteString
            == "http://localhost:11434/v1/chat/completions")
        #expect(Config.customEndpoint(fromBase: "http://localhost:11434/v1/chat/completions/")?.absoluteString
            == "http://localhost:11434/v1/chat/completions")
        // Pasted whitespace is tolerated.
        #expect(Config.customEndpoint(fromBase: " https://host/v1 ")?.absoluteString
            == "https://host/v1/chat/completions")
        // Scheme-less or non-http input could only fail at request time — reject it up front.
        #expect(Config.customEndpoint(fromBase: "myserver.local:8080/v1") == nil)
        #expect(Config.customEndpoint(fromBase: "ftp://host/v1") == nil)
        #expect(Config.customEndpoint(fromBase: "https://") == nil)
    }

    // MARK: excerpt cap

    @Test func excerptPassesThroughUnderCap() {
        let (excerpt, truncated) = ChatCompletionsPostProcessor.promptExcerpt(for: "short text")
        #expect(excerpt == "short text")
        #expect(!truncated)
    }

    @Test func excerptTruncatesHeadAndTailOverCap() {
        let text = String(repeating: "a", count: 300_000) + String(repeating: "z", count: 300_001)
        let (excerpt, truncated) = ChatCompletionsPostProcessor.promptExcerpt(for: text)
        #expect(truncated)
        #expect(excerpt.hasPrefix("aaa"))
        #expect(excerpt.hasSuffix("zzz"))
        #expect(excerpt.count < text.count)
    }

    // MARK: request building + happy path

    @Test func buildsBearerAuthRequestAndParsesNotes() async throws {
        let requestBox = Mutex<URLRequest?>(nil)
        let body = okBody(content: #"{"title": "Roadmap sync", "summary": "We planned Q3.", "actionItems": ["Ship it"]}"#)
        MockURLProtocol.handler = { request in
            requestBox.withLock { $0 = request }
            return (200, body)
        }
        let processor = ChatCompletionsPostProcessor(
            config: openAIConfig, apiKeyProvider: { "sk-test" }, session: mockedSession())
        let result = try await processor.process(transcript: longTranscript(), audio: nil)
        #expect(result.title == "Roadmap sync")
        #expect(result.summary == "We planned Q3.")
        #expect(result.actionItems == ["Ship it"])
        #expect(result.truncated == false)

        let request = requestBox.withLock { $0 }
        #expect(request?.url?.absoluteString == "https://api.openai.com/v1/chat/completions")
        #expect(request?.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        #expect(request?.value(forHTTPHeaderField: "Content-Type") == "application/json")
        // URLSession moves the body to a stream under URLProtocol; rebuild it for inspection.
        let sent = ChatCompletionsPostProcessor.makeRequest(
            config: openAIConfig, excerpt: "x", apiKey: "sk-test")
        let sentBody = try JSONSerialization.jsonObject(with: sent.httpBody!) as! [String: Any]
        #expect(sentBody["model"] as? String == "gpt-5-mini")
        let messages = sentBody["messages"] as! [[String: String]]
        #expect(messages.count == 2)
        #expect(messages[0]["role"] == "system")
        #expect(messages[1]["role"] == "user")
        #expect(messages[1]["content"]!.contains("x"))
        #expect(sentBody["temperature"] == nil)
        #expect(sentBody["max_tokens"] == nil)
    }

    // MARK: parsing edge cases

    @Test func stripsCodeFencesAndProse() throws {
        let content = "Here you go:\n```json\n{\"title\": \"T\", \"summary\": \"S\", \"actionItems\": []}\n```"
        let result = try ChatCompletionsPostProcessor.notes(
            fromResponseBody: okBody(content: content), truncated: true)
        #expect(result.title == "T")
        #expect(result.summary == "S")
        #expect(result.actionItems == nil)   // empty array → nil, matching on-device mapping
        #expect(result.truncated)
    }

    @Test func missingKeysDecodeLeniently() throws {
        let result = try ChatCompletionsPostProcessor.notes(
            fromResponseBody: okBody(content: #"{"summary": "Only a summary."}"#), truncated: false)
        #expect(result.title == nil)
        #expect(result.summary == "Only a summary.")
    }

    @Test func emptyContentThrows() {
        #expect(throws: CloudSummaryError.self) {
            try ChatCompletionsPostProcessor.notes(
                fromResponseBody: okBody(content: ""), truncated: false)
        }
    }

    @Test func nonJSONContentThrows() {
        #expect(throws: CloudSummaryError.self) {
            try ChatCompletionsPostProcessor.notes(
                fromResponseBody: okBody(content: "I could not summarize this."), truncated: false)
        }
    }

    // MARK: failure paths

    @Test func non200Throws() async {
        MockURLProtocol.handler = { _ in (401, Data()) }
        let processor = ChatCompletionsPostProcessor(
            config: openAIConfig, apiKeyProvider: { "bad" }, session: mockedSession())
        await #expect(throws: CloudSummaryError.self) {
            _ = try await processor.process(transcript: longTranscript(), audio: nil)
        }
    }

    @Test func missingKeyThrowsWithoutNetwork() async {
        MockURLProtocol.handler = { _ in
            Issue.record("no request should be sent without a key")
            return (500, Data())
        }
        let processor = ChatCompletionsPostProcessor(
            config: openAIConfig, apiKeyProvider: { nil }, session: mockedSession())
        await #expect(throws: CloudSummaryError.self) {
            _ = try await processor.process(transcript: longTranscript(), audio: nil)
        }
    }

    @Test func shortTranscriptThrowsTooShort() async {
        let processor = ChatCompletionsPostProcessor(
            config: openAIConfig, apiKeyProvider: { "k" }, session: mockedSession())
        await #expect(throws: PostProcessingError.self) {
            _ = try await processor.process(transcript: longTranscript(words: 5), audio: nil)
        }
    }
}

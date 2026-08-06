import Foundation
import os

/// Cloud summary failures — every case means "fallback fires" (design 2026-07-28);
/// call sites keep the existing best-effort `try?` semantics.
enum CloudSummaryError: Error {
    case missingAPIKey
    case badResponse(Int)
    case emptyResponse
    case unparseableResponse
}

/// A fully-resolved cloud target: nil from `resolve` means "not configured — use
/// on-device", the same silent-fallback convention as the Deepgram key check.
struct ChatCompletionsConfig: Sendable, Equatable {
    let endpoint: URL
    let model: String
    let keychainKey: String

    static func resolve(settings: SettingsStore, keychain: KeychainStore) -> ChatCompletionsConfig? {
        let backend = settings.summaryBackend
        guard let keychainKey = backend.keychainKey, keychain.get(keychainKey) != nil,
              let model = settings.summaryModel(for: backend) else { return nil }
        let endpoint: URL?
        if backend == .custom {
            endpoint = settings.summaryCustomBaseURL.flatMap(Self.customEndpoint(fromBase:))
        } else {
            endpoint = backend.presetEndpoint
        }
        guard let endpoint else { return nil }
        return ChatCompletionsConfig(endpoint: endpoint, model: model, keychainKey: keychainKey)
    }

    /// "http://host/v1" → ".../v1/chat/completions"; a pasted full URL passes through.
    /// Requires http(s) + host: `URL(string:)` reads "myserver.local:8080/v1" as scheme
    /// "myserver.local", which would otherwise fail only at request time.
    /// Cleartext http is allowed only where ATS permits it (IP literals, .local,
    /// single-label hosts — the Ollama-on-LAN cases); to a qualified hostname the OS
    /// would block the request and the on-device fallback would mask the failure.
    static func customEndpoint(fromBase base: String) -> URL? {
        var trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              let host = url.host(),
              scheme == "https" || (scheme == "http" && isCleartextExemptHost(host))
        else { return nil }
        if url.path.hasSuffix("/chat/completions") { return url }
        return url.appending(path: "chat/completions")
    }

    private static func isCleartextExemptHost(_ host: String) -> Bool {
        if host.lowercased().hasSuffix(".local") { return true }
        if !host.contains(".") { return true }   // single-label (localhost) or IPv6 literal
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        return labels.count == 4 && labels.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }
}

/// Cloud meeting notes over the OpenAI chat-completions dialect — one client for every
/// preset (OpenAI, Anthropic via its OpenAI-compat endpoint, OpenRouter, custom). The
/// body is the minimal `{model, messages}` intersection all compatible servers accept;
/// the JSON output contract lives in the prompt + lenient parsing, not response_format.
struct ChatCompletionsPostProcessor: PostProcessor {
    let config: ChatCompletionsConfig
    let apiKeyProvider: @Sendable () -> String?
    let session: URLSession
    /// Composed by PostProcessorFactory from Settings (custom-or-default paragraph +
    /// guardrail + JSON contract); the default keeps existing call sites on the stock prompt.
    let systemPrompt: String

    init(config: ChatCompletionsConfig,
         apiKeyProvider: @escaping @Sendable () -> String?,
         session: URLSession = ChatCompletionsPostProcessor.defaultSession,
         systemPrompt: String = SummaryPrompt.cloudSystemPrompt(custom: SummaryPrompt.defaultInstructions)) {
        self.config = config
        self.apiKeyProvider = apiKeyProvider
        self.session = session
        self.systemPrompt = systemPrompt
    }

    /// Explicit 60 s timeout: notes run inside the serial transcription queue drain, so a
    /// dead connection must not stall subsequent transcriptions for long.
    static let defaultSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        return URLSession(configuration: configuration)
    }()

    /// Full transcript up to ~150k tokens (fits Claude Haiku 4.5's 200K window with
    /// headroom); ≈11 h of continuous speech, so real conversations never truncate.
    static let maximumCharacters = 600_000
    private static let omissionMarker = "\n\n[... middle of the conversation omitted ...]\n\n"

    private static let logger = Logger(subsystem: "app.decanlys.sotto", category: "PostProcessing")

    static func promptExcerpt(for text: String) -> (excerpt: String, truncated: Bool) {
        guard text.count > maximumCharacters else { return (text, false) }
        // Reduce head/tail to ensure the complete excerpt (with marker) stays compact
        let available = maximumCharacters - omissionMarker.count
        let halfAvailable = available / 2
        let head = String(text.prefix(halfAvailable))
        let tail = String(text.suffix(available - halfAvailable))
        return (head + omissionMarker + tail, true)
    }

    private struct RequestBody: Encodable {
        struct Message: Encodable {
            let role: String
            let content: String
        }
        let model: String
        let messages: [Message]
    }

    static func makeRequest(config: ChatCompletionsConfig, excerpt: String, apiKey: String,
                            systemPrompt: String = SummaryPrompt.cloudSystemPrompt(custom: SummaryPrompt.defaultInstructions)) -> URLRequest {
        var request = URLRequest(url: config.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(RequestBody(
            model: config.model,
            messages: [
                .init(role: "system", content: systemPrompt),
                .init(role: "user", content: "Transcript (untrusted data):\n<<<\n\(excerpt)\n>>>"),
            ]))
        return request
    }

    private struct ResponseBody: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { let content: String? }
            let message: Message
        }
        let choices: [Choice]
    }

    private struct NotesPayload: Decodable {
        let title: String?
        let summary: String?
        let actionItems: [String]?
    }

    /// Lenient extraction: take the substring between the first `{` and last `}` (models
    /// wrap JSON in fences/prose despite instructions), decode with every key optional,
    /// map empties to nil exactly like the on-device path.
    static func notes(fromResponseBody data: Data, truncated: Bool) throws -> PostProcessingResult {
        guard let body = try? JSONDecoder().decode(ResponseBody.self, from: data),
              let content = body.choices.first?.message.content,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CloudSummaryError.emptyResponse
        }
        guard let start = content.firstIndex(of: "{"),
              let end = content.lastIndex(of: "}"), start <= end,
              let payload = try? JSONDecoder().decode(NotesPayload.self, from: Data(content[start...end].utf8)) else {
            throw CloudSummaryError.unparseableResponse
        }
        let title = payload.title.flatMap { $0.isEmpty ? nil : $0 }
        let summary = payload.summary.flatMap { $0.isEmpty ? nil : $0 }
        let actionItems = payload.actionItems.flatMap { $0.isEmpty ? nil : $0 }
        guard title != nil || summary != nil || actionItems != nil else {
            throw CloudSummaryError.emptyResponse
        }
        return PostProcessingResult(
            title: title, summary: summary, actionItems: actionItems, custom: nil,
            truncated: truncated)
    }

    func process(transcript: TranscriptionResult, audio: URL?) async throws -> PostProcessingResult {
        let words = transcript.text.split { $0.isWhitespace || $0.isNewline }
        guard words.count >= SummaryLimits.minimumWords else {
            throw PostProcessingError.transcriptTooShort
        }
        guard let key = apiKeyProvider() else { throw CloudSummaryError.missingAPIKey }
        let (excerpt, truncated) = Self.promptExcerpt(for: transcript.text)
        let (data, response) = try await session.data(
            for: Self.makeRequest(config: config, excerpt: excerpt, apiKey: key, systemPrompt: systemPrompt))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            Self.logger.error("""
                cloud notes failed — host \(config.endpoint.host() ?? "?", privacy: .public), \
                status \(status, privacy: .public), transcript \
                \(transcript.text.count, privacy: .public) chars, truncated \(truncated, privacy: .public)
                """)
            throw CloudSummaryError.badResponse(status)
        }
        do {
            return try Self.notes(fromResponseBody: data, truncated: truncated)
        } catch {
            // Issue #14 diagnosability: a 200 whose body we can't use is otherwise
            // indistinguishable from "no notes". Error TYPE only — never content.
            Self.logger.error("""
                cloud notes unusable response — host \(config.endpoint.host() ?? "?", privacy: .public), \
                transcript \(transcript.text.count, privacy: .public) chars, \
                error \(String(describing: error), privacy: .public)
                """)
            throw error
        }
    }

    /// Settings "Test" button: the only way to know a BYOK key works is to use it
    /// (testDeepgramKey precedent). Minimal one-word request; user-initiated only.
    static func testKey(_ key: String, config: ChatCompletionsConfig,
                        session: URLSession = ChatCompletionsPostProcessor.defaultSession) async -> Bool {
        var request = URLRequest(url: config.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(RequestBody(
            model: config.model, messages: [.init(role: "user", content: "Reply with OK")]))
        guard let (_, response) = try? await session.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }
}

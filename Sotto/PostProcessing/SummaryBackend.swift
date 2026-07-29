import Foundation

/// Which engine produces meeting notes. `onDevice` is the default (Apple Foundation
/// Models); the cloud cases share ONE OpenAI-chat-completions client — each preset is
/// just endpoint + default-model data (design 2026-07-28). Mirrors `TranscriptionBackend`.
enum SummaryBackend: String, Codable, Sendable, CaseIterable {
    case onDevice, openAI, anthropic, openRouter, custom
}

extension SummaryBackend {
    var displayName: String {
        switch self {
        case .onDevice: "On-device"
        case .openAI: "OpenAI"
        case .anthropic: "Anthropic"
        case .openRouter: "OpenRouter"
        case .custom: "Custom endpoint"
        }
    }

    /// Full chat-completions URL for presets; nil for onDevice and custom (custom builds
    /// its endpoint from `SettingsStore.summaryCustomBaseURL`). Anthropic goes through its
    /// documented OpenAI-compatibility endpoint — same request dialect as the others.
    var presetEndpoint: URL? {
        switch self {
        case .onDevice, .custom: nil
        case .openAI: URL(string: "https://api.openai.com/v1/chat/completions")
        case .anthropic: URL(string: "https://api.anthropic.com/v1/chat/completions")
        case .openRouter: URL(string: "https://openrouter.ai/api/v1/chat/completions")
        }
    }

    /// Cheap-tier defaults; config strings, safe to update as providers rotate models.
    var defaultModel: String? {
        switch self {
        case .onDevice, .custom: nil
        case .openAI: "gpt-5-mini"
        case .anthropic: "claude-haiku-4-5"
        case .openRouter: "openai/gpt-5-mini"
        }
    }

    /// Per-provider Keychain slots so switching providers never loses a pasted key
    /// (SPEC: secrets in Keychain, never UserDefaults — same split as deepgramAPIKey).
    var keychainKey: String? {
        switch self {
        case .onDevice: nil
        case .openAI: "summaryAPIKey.openai"
        case .anthropic: "summaryAPIKey.anthropic"
        case .openRouter: "summaryAPIKey.openrouter"
        case .custom: "summaryAPIKey.custom"
        }
    }
}

/// Summary settings follow the transcriptionEngine precedent: the stored value is the
/// user's *preference*; the factory still requires a Keychain key before picking cloud.
extension SettingsStore {
    var summaryBackend: SummaryBackend {
        get {
            defaults.string(forKey: "summaryBackend")
                .flatMap(SummaryBackend.init(rawValue:)) ?? .onDevice
        }
        nonmutating set { defaults.set(newValue.rawValue, forKey: "summaryBackend") }
    }

    /// Raw per-provider override (what the Settings text field edits); nil = use default.
    func summaryModelOverride(for backend: SummaryBackend) -> String? {
        defaults.string(forKey: "summaryModel.\(backend.rawValue)")
    }

    func setSummaryModel(_ model: String?, for backend: SummaryBackend) {
        defaults.set(model, forKey: "summaryModel.\(backend.rawValue)")
    }

    /// Resolved model: override wins, else the preset default (nil for custom w/o override).
    func summaryModel(for backend: SummaryBackend) -> String? {
        summaryModelOverride(for: backend) ?? backend.defaultModel
    }

    /// Custom endpoint base URL, e.g. "http://192.168.1.5:11434/v1".
    var summaryCustomBaseURL: String? {
        get { defaults.string(forKey: "summaryCustomBaseURL") }
        nonmutating set { defaults.set(newValue, forKey: "summaryCustomBaseURL") }
    }
}

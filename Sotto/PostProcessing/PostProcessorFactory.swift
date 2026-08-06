import Foundation
import os

/// Cloud-first with on-device rescue (design 2026-07-28): try `primary`; on ANY throw run
/// `fallback` when present. Mirrors WiFiGatedService's wrapping pattern. Worst case equals
/// today's behavior; retry remains the existing re-transcribe button.
struct FallbackPostProcessor: PostProcessor {
    let primary: any PostProcessor
    let fallback: (any PostProcessor)?

    private static let logger = Logger(subsystem: "app.decanlys.sotto", category: "PostProcessing")

    func process(transcript: TranscriptionResult, audio: URL?) async throws -> PostProcessingResult {
        do {
            return try await primary.process(transcript: transcript, audio: audio)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Cancellation is teardown, not a provider failure — don't spend an on-device
            // run on a result nobody awaits. URLSession surfaces it as URLError(.cancelled),
            // hence the task re-check beyond the typed catch above.
            try Task.checkCancellation()
            // Issue #14 diagnosability: without this, "cloud configured but every summary
            // quietly came from on-device" is invisible. Error TYPE only — never content.
            Self.logger.notice("""
                cloud notes failed, \(fallback == nil ? "no fallback" : "falling back to on-device", privacy: .public) — \
                error \(String(describing: error), privacy: .public)
                """)
            guard let fallback else { throw error }
            return try await fallback.process(transcript: transcript, audio: audio)
        }
    }
}

/// THE single composition rule for meeting notes — both the queue path
/// (TranscriptionQueue's postProcessorProvider) and the merge path
/// (AppModel.regenerateNotes) call this, so the two can never drift.
/// `lowPowerMode`/`onDeviceAvailable` are parameters purely for deterministic tests.
enum PostProcessorFactory {
    static func make(
        settings: SettingsStore, keychain: KeychainStore,
        lowPowerMode: Bool = ProcessInfo.processInfo.isLowPowerModeEnabled,
        onDeviceAvailable: Bool = FoundationModelsPostProcessor.isModelAvailable
    ) -> (any PostProcessor)? {
        // SPEC Low Power detection — one rule for all providers: transcripts still ship,
        // only best-effort notes are skipped (kept deliberately; revisit if desired).
        guard !lowPowerMode else { return nil }
        let custom = settings.summaryPromptInstructions
        let onDevice: (any PostProcessor)? = onDeviceAvailable
            ? FoundationModelsPostProcessor(instructions: SummaryPrompt.onDeviceInstructions(custom: custom))
            : nil
        guard let config = ChatCompletionsConfig.resolve(settings: settings, keychain: keychain) else {
            return onDevice   // silent fallback when unconfigured — Deepgram convention
        }
        let cloud = ChatCompletionsPostProcessor(
            config: config, apiKeyProvider: { KeychainStore().get(config.keychainKey) },
            systemPrompt: SummaryPrompt.cloudSystemPrompt(custom: custom))
        return FallbackPostProcessor(primary: cloud, fallback: onDevice)
    }

    /// Issue #14 semantics for the detail view: is a missing summary a failure (some
    /// engine could have run) or expected (no engine exists on this device)?
    static func summariesAvailable(
        settings: SettingsStore, keychain: KeychainStore,
        onDeviceAvailable: Bool = FoundationModelsPostProcessor.isModelAvailable
    ) -> Bool {
        onDeviceAvailable
            || ChatCompletionsConfig.resolve(settings: settings, keychain: keychain) != nil
    }
}

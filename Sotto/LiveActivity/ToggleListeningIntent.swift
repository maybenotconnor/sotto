import AppIntents
import Foundation

/// Indirection seam so this shared file (compiled into both the app AND widget extension
/// targets) stays dependency-free: the widget target never registers `toggle`, so
/// perform() there is simply a no-op await.
@MainActor
final class IntentHandlers {
    static let shared = IntentHandlers()

    /// Registered by AppModel at construction; awaited by ToggleListeningIntent.perform().
    var toggle: (() async -> Void)?
}

/// AudioRecordingIntent (iOS 18+) is Apple's sanctioned mechanism for starting/stopping
/// recording from a Live Activity — the ONLY reliable way to restart the mic without
/// foregrounding the app (SPEC "Live Activity" job 1). The system runs perform() in the
/// APP process (launching it in the background if needed).
struct ToggleListeningIntent: AudioRecordingIntent {
    static let title: LocalizedStringResource = "Pause or resume listening"

    // @MainActor: perform() itself must share IntentHandlers' isolation domain — reading a
    // MainActor-isolated closure property from a nonisolated context and calling it there
    // would require the closure to be @Sendable, which an `async -> Void` capturing
    // [weak self] on AppModel is not.
    @MainActor
    func perform() async throws -> some IntentResult {
        // Awaiting the real toggle keeps the background-launched app process alive until
        // the mic actually starts/stops (M3 review Critical #2: fire-and-forget posts are
        // dropped when no scene/observer exists on a cold background launch).
        await IntentHandlers.shared.toggle?()
        return .result()
    }
}

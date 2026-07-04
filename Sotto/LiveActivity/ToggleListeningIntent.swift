import AppIntents
import Foundation

extension Notification.Name {
    /// Posted by ToggleListeningIntent.perform() — the app observes this and toggles the
    /// pipeline. Indirection keeps this file dependency-free for the widget target.
    static let sottoToggleListening = Notification.Name("sottoToggleListening")
}

/// AudioRecordingIntent (iOS 18+) is Apple's sanctioned mechanism for starting/stopping
/// recording from a Live Activity — the ONLY reliable way to restart the mic without
/// foregrounding the app (SPEC "Live Activity" job 1). The system runs perform() in the
/// APP process (launching it in the background if needed).
struct ToggleListeningIntent: AudioRecordingIntent {
    static let title: LocalizedStringResource = "Pause or resume listening"

    func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(name: .sottoToggleListening, object: nil)
        return .result()
    }
}

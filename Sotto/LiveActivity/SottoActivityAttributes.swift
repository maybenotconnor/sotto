import ActivityKit
import Foundation

/// Shared between the app (starts/updates the activity) and SottoWidgets (renders it).
/// Keep this file dependency-free — the widget target compiles it.
struct SottoActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var stateLabel: String        // "Listening" / "Recording" / "Paused — call" / "Paused by you"
        var conversationCount: Int
        var isPaused: Bool
    }

    /// Session start, for the elapsed-time timer on the lock screen.
    let startedAt: Date
}

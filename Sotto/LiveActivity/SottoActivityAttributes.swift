import ActivityKit
import Foundation

/// Shared between the app (starts/updates the activity) and SottoWidgets (renders it).
/// Keep this file dependency-free — the widget target compiles it.
struct SottoActivityAttributes: ActivityAttributes {
    /// What the session is actually doing. The widget derives all visuals (glyph,
    /// tint, label) from this; raw-value Codable is the wire format across the
    /// app/widget process boundary — don't rename cases casually.
    enum Phase: String, Codable, Hashable {
        case listening, recording, pausedByUser, pausedBySystem

        var isPaused: Bool { self == .pausedByUser || self == .pausedBySystem }
    }

    struct ContentState: Codable, Hashable {
        var phase: Phase
        var conversationCount: Int
    }

    /// Session start, for the elapsed-time timer on the lock screen.
    let startedAt: Date
}

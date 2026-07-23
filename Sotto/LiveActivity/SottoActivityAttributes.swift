import ActivityKit
import Foundation

/// Shared between the app (starts/updates the activity) and SottoWidgets (renders it).
/// Keep this file dependency-free — the widget target compiles it.
struct SottoActivityAttributes: ActivityAttributes {
    /// What the session is actually doing. The widget derives all visuals (glyph,
    /// tint, label) from this; raw-value Codable is the wire format across the
    /// app/widget process boundary — don't rename cases casually.
    enum Phase: String, Codable, Hashable {
        case listening, recording, pausedByUser, pausedBySystem, waiting

        var isPaused: Bool { self == .pausedByUser || self == .pausedBySystem }
    }

    struct ContentState: Codable, Hashable {
        var phase: Phase
        var conversationCount: Int
        /// M12: capture-source label ("Omi" / "iPhone mic"); nil pre-M12 or phone-mic-only.
        /// Defaulted so existing `ContentState(phase:conversationCount:)` call sites keep
        /// compiling — additive to the wire format shared with SottoWidgets.
        var sourceLabel: String? = nil
    }

    /// Session start, for the elapsed-time timer on the lock screen.
    let startedAt: Date
}

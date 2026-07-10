import SwiftUI

/// The home header's state machine (moved from ContentView's HomeScreen, made internal
/// and purely derived so it is unit-testable). One segment-open case takes priority over
/// the raw pipeline status so the card morphs into "Recording…" instead of growing a
/// second header-like row (M9 decision, preserved by the 2026-07-10 header refresh).
enum HeaderState: Equatable {
    case idle
    case starting
    case interrupted(ListeningPipeline.HaltReason?)
    case listening(sessionStart: Date?)
    case segmentOpen(start: Date)

    init(
        segmentStart: Date?,
        status: ListeningPipeline.Status,
        haltReason: ListeningPipeline.HaltReason?,
        sessionStart: Date?
    ) {
        if let segmentStart {
            self = .segmentOpen(start: segmentStart)
        } else {
            switch status {
            case .idle: self = .idle
            case .starting: self = .starting
            case .interrupted: self = .interrupted(haltReason)
            case .listening, .recording, .silence:
                self = .listening(sessionStart: sessionStart)
            }
        }
    }

    var label: String {
        switch self {
        case .idle: "Idle"
        case .starting: "Starting…"
        case .interrupted(let reason): reason == .userPause ? "Paused by you" : "Paused — call"
        case .listening: "Listening"
        case .segmentOpen: "Recording…"
        }
    }

    var dotColor: Color {
        switch self {
        case .idle, .starting: .secondary
        case .interrupted: .orange
        case .listening: .green
        case .segmentOpen: .red
        }
    }

    /// One timer at a time: the segment timer while a segment is open, else the session
    /// timer while listening/silence, else none.
    var timerStart: Date? {
        switch self {
        case .segmentOpen(let start): start
        case .listening(let sessionStart): sessionStart
        case .idle, .starting, .interrupted: nil
        }
    }

    /// Static subtitle shown when no timer runs (spec: idle only).
    var subtitle: String? {
        if case .idle = self { return "Ready to listen" }
        return nil
    }
}

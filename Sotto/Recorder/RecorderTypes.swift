import Foundation

/// The five recorder states from SPEC "State machine". `.idle` and `.interrupted` are
/// terminal-ish (chunks are ignored); the other three are the active listening loop.
enum RecorderState: String, Sendable, Equatable {
    case idle
    case listening
    case recording
    case silence
    case interrupted
}

struct RecorderSnapshot: Sendable, Equatable {
    var state: RecorderState
    var finalizedCount: Int
    var lastEvent: String?
    /// M6b: mirrors the machine's disk-guard flag so the Main screen can show a persistent
    /// "low disk space" banner instead of pattern-matching `lastEvent` strings. Defaulted so
    /// existing `RecorderSnapshot(state:finalizedCount:lastEvent:)` call sites keep compiling.
    var diskGuardActive: Bool = false
    /// M9: the currently-open segment's start date, non-nil exactly while a segment is
    /// recording/silence-pending-finalize (drives the unified home's live "Recording…" row
    /// timer). Defaulted so existing explicit `RecorderSnapshot(...)` call sites keep compiling.
    var currentSegmentStartDate: Date? = nil
}

struct RecorderConfig: Sendable {
    /// App-level conversation gap (SPEC default 45 s) — NOT the VAD's ~0.75 s hysteresis.
    var silenceTimeout: TimeInterval = 45
    var minSegmentSpeechDuration: TimeInterval = 3
    var maxSegmentDuration: TimeInterval = 7_200
    var preRollCapacity: Int = VADConstants.sampleRate   // 1.0 s
    var minFreeDiskBytes: Int64 = 500_000_000
}

/// Seam between the MainActor pipeline facade and the recorder actor.
protocol SegmentRecording: Sendable {
    func beginListening() async -> RecorderSnapshot
    func process(_ chunk: AudioChunk) async -> RecorderSnapshot
    /// Stop semantics: finalize any open segment, return to idle.
    func finishAndFinalize() async -> RecorderSnapshot
    /// Interruption semantics (M3 wires callers): finalize what exists, park.
    func markInterrupted() async -> RecorderSnapshot
}

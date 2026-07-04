import Foundation

enum SpeechEvent: Sendable, Equatable {
    case speechStart(time: TimeInterval?)
    case speechEnd(time: TimeInterval?)
}

/// Seam over the VAD implementation. FluidAudio's `VadManager` is beta — everything
/// downstream depends on this protocol so the engine can be swapped (e.g. for Apple's
/// `SpeechDetector` if it ever decouples from the transcriber).
///
/// Callers must serialize `process(_:)` and `reset()` — concurrent calls interleave
/// across the detector's internal suspension points and can clobber streaming state.
/// The pipeline's single pump task satisfies this.
protocol SpeechDetecting: Sendable {
    /// Feed one 4096-sample chunk; returns an event on speech-state transitions, else nil.
    func process(_ chunk: AudioChunk) async throws -> SpeechEvent?
    /// Clear streaming state (call on stop, and in M3 after interruptions).
    func reset() async
}

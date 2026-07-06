import Foundation

/// A fixed-size chunk of 16 kHz mono Float32 audio — the currency of the whole pipeline.
/// Value type on purpose: `AVAudioPCMBuffer` is not `Sendable` and must never cross
/// an async boundary (see SPEC "Audio source layer").
struct AudioChunk: Sendable, Equatable {
    let samples: [Float]
    let hostTime: UInt64
}

enum AudioSourceType: String, Codable, Sendable {
    case phoneMic
    case omi

    /// User-facing label (home header, Live Activity, Settings, detail view).
    var displayName: String {
        switch self {
        case .phoneMic: "iPhone mic"
        case .omi: "Omi"
        }
    }
}

protocol AudioSource: Sendable {
    var sourceType: AudioSourceType { get }
    var isAvailable: Bool { get }
    /// Emits fixed-size chunks of 4096 samples (256 ms @ 16 kHz).
    func start() async throws -> AsyncStream<AudioChunk>
    /// Contract: MUST terminate the stream returned by `start()` (finish its continuation)
    /// on every path — `ListeningPipeline.stop()` awaits stream termination to drain
    /// in-flight chunks and would otherwise never return, freezing the MainActor.
    /// Must also be safe to call when the source was never started (no-op), and be
    /// idempotent: `ListeningPipeline.deinit` calls `stop()` again even after an owner
    /// has already stopped the pipeline, so a second call must be harmless.
    func stop() async
}

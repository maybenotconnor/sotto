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
}

protocol AudioSource: Sendable {
    var sourceType: AudioSourceType { get }
    var isAvailable: Bool { get }
    /// Emits fixed-size chunks of 4096 samples (256 ms @ 16 kHz).
    func start() async throws -> AsyncStream<AudioChunk>
    func stop() async
}

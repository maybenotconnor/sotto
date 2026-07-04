import Foundation

/// Which engine produced a `TranscriptionResult`. `speechAnalyzer` is the on-device default
/// (SPEC); `deepgram` is the BYOK cloud fallback that additionally provides diarization.
enum TranscriptionBackend: String, Codable, Sendable {
    case speechAnalyzer, deepgram
}

/// One utterance/turn within a transcription. `speaker` is nil for on-device backends,
/// which do not diarize.
struct TranscriptionSegment: Codable, Sendable, Equatable {
    let speaker: String?          // nil for on-device backends
    let text: String
    let startTime: TimeInterval
    let endTime: TimeInterval
}

/// The full output of transcribing one audio file.
struct TranscriptionResult: Codable, Sendable, Equatable {
    let text: String
    let segments: [TranscriptionSegment]
    let duration: TimeInterval
    let backend: TranscriptionBackend
}

enum TranscriptionError: Error {
    case unavailable
    case missingAPIKey
    case badResponse(Int)
    case emptyAudio
}

/// A transcription engine: on-device (SpeechAnalyzer) or cloud (Deepgram). Implementations
/// are actors or otherwise internally synchronized — the queue calls this from its own
/// serial drain loop but may be replaced by fakes in tests.
protocol TranscriptionService: Sendable {
    var backend: TranscriptionBackend { get }
    func transcribe(file: URL) async throws -> TranscriptionResult
}

/// A persisted unit of work for `TranscriptionQueue`: one finalized segment on its way to
/// becoming a markdown transcript. `cafURL` is cleared once the deferred transcode has run
/// (or once salvage is discovered to have already run it) — nil means "only the m4a matters
/// from here on".
struct TranscriptionJob: Codable, Sendable, Equatable, Identifiable {
    enum State: String, Codable, Sendable {
        case pending, done, failed
    }

    let id: UUID
    var cafURL: URL?              // nil once transcoded (or salvaged externally)
    let m4aURL: URL
    let startDate: Date
    let duration: TimeInterval
    let speechDuration: TimeInterval
    var attempts: Int
    var state: State
}

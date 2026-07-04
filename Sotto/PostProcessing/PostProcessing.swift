import Foundation

/// SPEC "Post-processing hook", implemented M8: best-effort meeting notes; `title` added to
/// the spec's result shape.
struct PostProcessingResult: Codable, Sendable, Equatable {
    let title: String?
    let summary: String?
    let actionItems: [String]?
    let custom: [String: String]?
}

enum PostProcessingError: Error {
    case modelUnavailable
    case transcriptTooShort
}

protocol PostProcessor: Sendable {
    func process(transcript: TranscriptionResult, audio: URL?) async throws -> PostProcessingResult
}

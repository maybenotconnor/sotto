import Foundation

/// SPEC "Post-processing hook", implemented M8: best-effort meeting notes; `title` added to
/// the spec's result shape.
struct PostProcessingResult: Codable, Sendable, Equatable {
    let title: String?
    let summary: String?
    let actionItems: [String]?
    let custom: [String: String]?
    /// True when the transcript was too long to send whole and only head+tail excerpts were
    /// summarized. Drives the "based on excerpts" disclaimer in the written notes. Last
    /// property + default keeps the synthesized memberwise init backward-compatible.
    var truncated: Bool = false
}

enum PostProcessingError: Error {
    case modelUnavailable
    case transcriptTooShort
}

protocol PostProcessor: Sendable {
    func process(transcript: TranscriptionResult, audio: URL?) async throws -> PostProcessingResult
}

import Foundation

/// A finished conversation segment: the transcoded .m4a plus timing metadata.
/// M4's transcription queue consumes these; M5 derives `speechEnd` frontmatter
/// as `startDate + speechDuration`.
struct FinalizedSegment: Sendable, Equatable {
    let audioURL: URL
    let startDate: Date
    let duration: TimeInterval
    let speechDuration: TimeInterval
}

/// One open segment on disk. Deliberately NOT Sendable — instances are created and
/// used exclusively inside the RecorderStateMachine actor.
protocol SegmentWriting {
    var writtenSampleCount: Int { get }
    func append(_ samples: [Float]) throws
    /// Transcodes the capture file to .m4a, deletes the capture file, returns the .m4a URL.
    func finalize() throws -> URL
    /// Deletes everything; the segment never happened (min-length guard).
    func discard()
}

protocol SegmentWriterFactory: Sendable {
    func makeWriter(startDate: Date) throws -> any SegmentWriting
}

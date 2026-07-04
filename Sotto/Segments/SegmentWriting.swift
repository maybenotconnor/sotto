import Foundation

/// A finished conversation segment: the closed capture file plus timing metadata.
/// M4's transcription queue consumes these — it owns the transcode from `cafURL` to
/// `m4aURL` and the CAF's eventual deletion. M5 derives `speechEnd` frontmatter as
/// `startDate + speechDuration`.
struct FinalizedSegment: Sendable, Equatable {
    /// Closed capture file, still on disk.
    let cafURL: URL
    /// Transcode DESTINATION — does not exist yet.
    let m4aURL: URL
    let startDate: Date
    let duration: TimeInterval
    let speechDuration: TimeInterval
}

/// One open segment on disk. Deliberately NOT Sendable — instances are created and
/// used exclusively inside the RecorderStateMachine actor.
protocol SegmentWriting {
    var writtenSampleCount: Int { get }
    var cafURL: URL { get }
    var m4aURL: URL { get }
    func append(_ samples: [Float]) throws
    /// FAST: flush + release the file handle. The CAF stays on disk; transcode is the
    /// transcription queue's job (M3 review Critical #1: a synchronous transcode of a
    /// 2 h segment inside the ~30 s interruption window watchdog-kills the app).
    func close()
    /// Deletes everything; the segment never happened (min-length guard).
    func discard()
}

protocol SegmentWriterFactory: Sendable {
    func makeWriter(startDate: Date) throws -> any SegmentWriting
}

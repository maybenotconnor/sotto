import Foundation

struct DaySegmentEntry: Codable, Sendable, Equatable {
    let id: String                    // file basename, e.g. "09-15-30"
    let startTime: Date
    var duration: TimeInterval
    var backend: String?              // nil until transcribed
    var hasAudio: Bool
    var wordCount: Int?
    var transcriptionState: String    // "queued" | "done" | "failed"
}

struct DayGapEntry: Codable, Sendable, Equatable {
    let from: Date
    let reason: String                // "uncleanShutdown"
}

struct DayIndex: Codable, Sendable, Equatable {
    let date: String                  // "2026-03-14"
    var segments: [DaySegmentEntry]
    var gaps: [DayGapEntry]
}

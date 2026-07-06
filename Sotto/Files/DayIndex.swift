import Foundation

struct DaySegmentEntry: Codable, Sendable, Equatable {
    let id: String                    // file basename, e.g. "09-15-30"
    let startTime: Date
    var duration: TimeInterval
    var backend: String?              // nil until transcribed
    var hasAudio: Bool
    var wordCount: Int?
    var transcriptionState: String    // "queued" | "done" | "failed"
    // M8 meeting notes: nil until a post-processor produces a title (or for pre-M8 files/no
    // notes at all). `String?`'s synthesized Decodable conformance already uses
    // `decodeIfPresent` under the hood, so M5-era `_day.json` files (written before this
    // field existed, with no "title" key at all) still load rather than failing to decode.
    var title: String? = nil
    // M12: capture device, raw AudioSourceType value ("omi"); nil = phone mic (pre-M12
    // files have no key — same decodeIfPresent story as `title`).
    var source: String? = nil
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

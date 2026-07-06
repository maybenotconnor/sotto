import Foundation

/// SPEC "File output": `_day.json` is rebuildable by scanning the folder's .md frontmatter.
/// Gaps are not recoverable from files; a rebuilt index has none.
enum DayIndexRebuilder {
    static func rebuild(dayDirectory: URL) -> DayIndex {
        let date = dayDirectory.lastPathComponent
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: dayDirectory, includingPropertiesForKeys: nil)) ?? []
        let mdFiles = contents.filter { $0.pathExtension == "md" }
        let m4aFiles = contents.filter { $0.pathExtension == "m4a" }

        var segments: [DaySegmentEntry] = []
        // Only ids that were SUCCESSFULLY parsed suppress the orphan-m4a fallback below —
        // an unreadable .md must still surface as a queued entry rather than vanish.
        var parsedIDs: Set<String> = []

        for md in mdFiles {
            guard let file = TranscriptFile.parse(url: md) else { continue }
            let front = file.frontmatter
            let id = md.deletingPathExtension().lastPathComponent
            let iso = ISO8601DateFormatter()
            let startTime = front["date"].flatMap { iso.date(from: $0) }
                ?? fallbackDate(dayName: date, id: id)
            parsedIDs.insert(id)
            segments.append(DaySegmentEntry(
                id: id,
                startTime: startTime,
                duration: front["duration"].flatMap(Double.init) ?? 0,
                backend: front["backend"],
                hasAudio: m4aFiles.contains { $0.deletingPathExtension().lastPathComponent == id },
                // M8 hardening Fix 5: count words from the parsed TRANSCRIPT body, not the
                // whole post-frontmatter body — a notes-bearing file's Summary/action-items
                // text would otherwise inflate the count with words nobody spoke.
                wordCount: wordCount(of: file.transcriptBody),
                transcriptionState: "done",
                title: front["title"]))
        }

        for m4a in m4aFiles {
            let id = m4a.deletingPathExtension().lastPathComponent
            guard !parsedIDs.contains(id) else { continue }
            segments.append(DaySegmentEntry(
                id: id,
                startTime: fallbackDate(dayName: date, id: id),
                duration: 0,
                backend: nil, hasAudio: true, wordCount: nil,
                transcriptionState: "queued"))
        }

        segments.sort { ($0.startTime, $0.id) < ($1.startTime, $1.id) }
        return DayIndex(date: date, segments: segments, gaps: [])
    }

    /// Fed `TranscriptFile.transcriptBody` (frontmatter stripped, and the Summary/action-items
    /// section excluded when notes are present — the shared parser above draws that line) —
    /// still strips speaker labels and heading markup, since those aren't "words".
    static func wordCount(of body: String) -> Int {
        let stripped = body
            .replacingOccurrences(of: #"\*\*Speaker \d+:\*\*"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: "#", with: " ")
        return stripped.split { $0.isWhitespace || $0.isNewline }.count
    }

    private static func fallbackDate(dayName: String, id: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        return formatter.date(from: "\(dayName) \(String(id.prefix(8)))") ?? .distantPast
    }
}

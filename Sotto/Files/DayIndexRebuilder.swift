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
            guard let text = try? String(contentsOf: md, encoding: .utf8) else { continue }
            let front = frontmatter(of: text)
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
                wordCount: wordCount(of: text),
                transcriptionState: "done"))
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

    private static func frontmatter(of text: String) -> [String: String] {
        let lines = text.components(separatedBy: "\n")
        guard lines.first == "---" else { return [:] }
        var result: [String: String] = [:]
        for line in lines.dropFirst() {
            if line == "---" { break }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            result[key] = value
        }
        return result
    }

    private static func wordCount(of text: String) -> Int {
        guard let bodyStart = text.range(of: "\n---\n") else { return 0 }
        let body = text[bodyStart.upperBound...]
            .replacingOccurrences(of: #"\*\*Speaker \d+:\*\*"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: "#", with: " ")
        return body.split { $0.isWhitespace || $0.isNewline }.count
    }

    private static func fallbackDate(dayName: String, id: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        return formatter.date(from: "\(dayName) \(String(id.prefix(8)))") ?? .distantPast
    }
}

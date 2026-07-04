import Foundation

/// Shared `.md` transcript parser (SPEC "File output" markdown format: YAML frontmatter +
/// body). Used by `DayIndexRebuilder` (backend/date/word-count) and by the List/Detail
/// screens (full body, preview snippet) — one parser, one source of truth for the shape.
struct TranscriptFile {
    let frontmatter: [String: String]
    let body: String

    /// Returns nil only when the file can't be read as UTF-8 text at all (SPEC: the folder
    /// is user-exposed via Files/Obsidian, so a missing/corrupt file is expected, not a bug).
    /// A file with no frontmatter block still parses — its whole contents become the body.
    static func parse(url: URL) -> TranscriptFile? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: "\n")
        guard lines.first == "---" else {
            return TranscriptFile(frontmatter: [:], body: text.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        var front: [String: String] = [:]
        var index = 1
        while index < lines.count, lines[index] != "---" {
            defer { index += 1 }
            guard let colon = lines[index].firstIndex(of: ":") else { continue }
            let key = String(lines[index][..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(lines[index][lines[index].index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            front[key] = value
        }
        // `index` now sits on the closing "---" (or past the end if the block never closed);
        // the body is everything after that line.
        let bodyLines = index < lines.count ? lines[(index + 1)...] : []
        let body = bodyLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return TranscriptFile(frontmatter: front, body: body)
    }

    /// List/Detail preview snippet: the `# Conversation — …` heading line dropped, remaining
    /// whitespace collapsed to single spaces, capped at ~160 characters.
    var previewText: String {
        let withoutHeading = body
            .components(separatedBy: "\n")
            .filter { !$0.hasPrefix("#") }
            .joined(separator: " ")
        let collapsed = withoutHeading
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return String(collapsed.prefix(160))
    }
}

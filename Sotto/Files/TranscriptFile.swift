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

    /// M8 meeting notes: the frontmatter `title:` value, nil for pre-M8/no-notes files.
    var title: String? { frontmatter["title"] }

    /// M8 meeting notes: the section between a `## Summary` heading and the next `## `
    /// heading (or the end of the body). Nil when the body has no `## Summary` section —
    /// i.e. every pre-M8 file and every M8 file whose post-processor produced no notes.
    var summary: String? {
        let lines = body.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.hasPrefix("## Summary") }) else { return nil }
        let rest = lines[(start + 1)...]
        let end = rest.firstIndex { $0.hasPrefix("## ") } ?? lines.endIndex
        let section = lines[(start + 1)..<end].joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return section.isEmpty ? nil : section
    }

    /// M8 meeting notes: the body after a `## Transcript` heading, when present — else the
    /// whole body unchanged (byte-compatible with pre-M8 files, which have no such heading).
    var transcriptBody: String {
        let lines = body.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.hasPrefix("## Transcript") }) else {
            return body
        }
        return lines[(start + 1)...].joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `transcriptBody` parsed as inline markdown for display — Deepgram's `**speaker**` turns
    /// become bold runs, whitespace and newlines are preserved. Uses the first-party
    /// `AttributedString(markdown:)` API with the same `.inlineOnlyPreservingWhitespace`
    /// semantics SwiftUI applies to `Text(_: LocalizedStringKey)`, so it renders identically
    /// without pressing `LocalizedStringKey` into service as a runtime markdown parser. Parsing
    /// returns the partially-parsed result rather than throwing, so malformed markdown still
    /// shows readable text.
    var transcriptBodyAttributed: AttributedString {
        let source = transcriptBody
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible)
        return (try? AttributedString(markdown: source, options: options))
            ?? AttributedString(source)
    }

    /// List/Detail preview snippet: prefers the `## Summary` section (M8 meeting notes) when
    /// present; otherwise the `transcriptBody` with its `# Conversation — …` heading line
    /// dropped. Whitespace collapsed to single spaces, capped at ~160 characters.
    var previewText: String {
        let source = summary ?? transcriptBody
        let withoutHeading = source
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

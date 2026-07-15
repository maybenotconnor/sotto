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

    /// The raw text of the `## Summary` section — everything between the `## Summary` heading
    /// and the next `## ` heading (or the end of the body). Includes the excerpt disclaimer
    /// line when present; `summary` strips it and `summaryIsExcerpt` detects it. Nil when the
    /// body has no `## Summary` section.
    private var rawSummarySection: String? {
        let lines = body.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.hasPrefix("## Summary") }) else { return nil }
        let rest = lines[(start + 1)...]
        let end = rest.firstIndex { $0.hasPrefix("## ") } ?? lines.endIndex
        let section = lines[(start + 1)..<end].joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return section.isEmpty ? nil : section
    }

    /// M8 meeting notes: the `## Summary` section with the excerpt disclaimer line removed.
    /// The disclaimer is trusted app text stored as markdown italic (`_..._`), but the in-app
    /// summary renders through a verbatim `Text(String)` that does NOT interpret markdown — so
    /// it's lifted out here and rendered separately, de-emphasized (see `summaryIsExcerpt`),
    /// keeping the untrusted model summary verbatim. Nil when there's no `## Summary` section
    /// (every pre-M8/no-notes file) or when the section holds nothing but the disclaimer.
    var summary: String? {
        guard let section = rawSummarySection else { return nil }
        let cleaned = section
            .components(separatedBy: "\n")
            .filter { $0 != TranscriptMarkdownWriter.excerptDisclaimer }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    /// True when the summary was built from head+tail excerpts of a long transcript — the
    /// writer appended `excerptDisclaimer` to the `## Summary` section. Drives the small,
    /// less-prominent disclaimer shown beneath the summary in the detail view.
    var summaryIsExcerpt: Bool {
        rawSummarySection?
            .components(separatedBy: "\n")
            .contains(TranscriptMarkdownWriter.excerptDisclaimer) ?? false
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
    /// without pressing `LocalizedStringKey` into service as a runtime markdown parser.
    var transcriptBodyAttributed: AttributedString { Self.attributed(transcriptBody) }

    /// Inline-markdown parse of a single string. Shared by `transcriptBodyAttributed` and the
    /// per-block rendering path (`transcriptBlocks`). Parsing returns the partially-parsed
    /// result rather than throwing, so malformed markdown still shows readable text.
    static func attributed(_ markdown: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible)
        return (try? AttributedString(markdown: markdown, options: options))
            ?? AttributedString(markdown)
    }

    /// One render unit of the transcript body. A single `Text` over the whole document blanks
    /// out past CoreText's single-layout ceiling and forces a synchronous full-document
    /// markdown parse on open; splitting into blocks lets a `LazyVStack` parse and lay out only
    /// the turns near the viewport. Ids are the block's position, stable for `ForEach` identity.
    struct TranscriptBlock: Identifiable {
        let id: Int
        let text: String
    }

    /// Upper bound on a block's character count. Comfortably under the single-`Text` ceiling
    /// while small enough that each block parses in well under a frame — Deepgram turns fall
    /// far below it, so only an on-device one-paragraph body is ever sub-split.
    static let maxBlockCharacters = 2_000

    /// The `transcriptBody` split into `LazyVStack` render blocks. Deepgram turns are already
    /// blank-line-separated paragraphs (one block each); an on-device transcript is one long
    /// paragraph, so any paragraph over `maxBlockCharacters` is wrapped at word boundaries so
    /// no block approaches the single-`Text` layout ceiling.
    var transcriptBlocks: [TranscriptBlock] {
        var blocks: [TranscriptBlock] = []
        for paragraph in Self.paragraphs(of: transcriptBody) {
            for piece in Self.wrap(paragraph, cap: Self.maxBlockCharacters) where !piece.isEmpty {
                blocks.append(TranscriptBlock(id: blocks.count, text: piece))
            }
        }
        return blocks
    }

    /// Split a body into paragraphs on blank-line runs, preserving single newlines within a
    /// paragraph. Empty (whitespace-only) lines are separators and never become their own block.
    private static func paragraphs(of body: String) -> [String] {
        body.components(separatedBy: "\n")
            .split(whereSeparator: { $0.trimmingCharacters(in: .whitespaces).isEmpty })
            .map { $0.joined(separator: "\n") }
    }

    /// Wrap one paragraph into pieces no longer than `cap`, breaking at the last whitespace
    /// at/under the cap so words stay intact (a single word longer than `cap` is hard-cut).
    /// The whitespace at each break is consumed — no words are dropped or reordered.
    private static func wrap(_ paragraph: String, cap: Int) -> [String] {
        guard paragraph.count > cap else { return [paragraph] }
        var pieces: [String] = []
        var remaining = Substring(paragraph)
        while remaining.count > cap {
            let hardIndex = remaining.index(remaining.startIndex, offsetBy: cap)
            let whitespaceBreak = remaining[..<hardIndex].lastIndex(where: \.isWhitespace)
            let breakIndex = whitespaceBreak.flatMap { $0 > remaining.startIndex ? $0 : nil } ?? hardIndex
            pieces.append(remaining[..<breakIndex].trimmingCharacters(in: .whitespaces))
            remaining = remaining[breakIndex...].drop(while: \.isWhitespace)
        }
        let tail = remaining.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { pieces.append(tail) }
        return pieces
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

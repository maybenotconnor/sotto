import Foundation
import Testing
@testable import Sotto

struct TranscriptFileTests {
    @Test func parsesFrontmatterBodyAndPreview() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TFTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("t.md")
        try """
        ---
        date: 2026-03-14T09:15:30-04:00
        backend: speechAnalyzer
        ---

        # Conversation — 9:15 AM

        Hello there. This is the body text that should appear in previews.
        """.write(to: url, atomically: true, encoding: .utf8)

        let file = try #require(TranscriptFile.parse(url: url))
        #expect(file.frontmatter["backend"] == "speechAnalyzer")
        #expect(file.body.contains("Hello there."))
        #expect(!file.previewText.contains("#"))
        #expect(file.previewText.hasPrefix("Hello there."))
    }

    @Test func parsesTitleSummaryAndTranscriptSections() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TFTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("t.md")
        try """
        ---
        date: 2026-03-14T09:15:30-04:00
        backend: speechAnalyzer
        title: Rollout sync
        ---

        # Rollout sync — 9:15 AM

        ## Summary

        Quick status sync about the beta.

        Action items:
        - File compliance

        ## Transcript

        We synced on the rollout and the beta numbers.
        """.write(to: url, atomically: true, encoding: .utf8)

        let file = try #require(TranscriptFile.parse(url: url))
        #expect(file.title == "Rollout sync")
        #expect(file.summary?.contains("Quick status sync") == true)
        #expect(file.transcriptBody.contains("We synced on the rollout"))
        #expect(!file.transcriptBody.contains("## Summary"))
        #expect(file.previewText.hasPrefix("Quick status sync"))   // preview prefers summary
    }

    @Test func filesWithoutNotesParseExactlyAsBefore() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TFTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("t.md")
        try """
        ---
        date: 2026-03-14T09:15:30-04:00
        backend: speechAnalyzer
        ---

        # Conversation — 9:15 AM

        Hello there. This is the body text that should appear in previews.
        """.write(to: url, atomically: true, encoding: .utf8)

        let file = try #require(TranscriptFile.parse(url: url))
        #expect(file.frontmatter["backend"] == "speechAnalyzer")
        #expect(file.body.contains("Hello there."))
        #expect(!file.previewText.contains("#"))
        #expect(file.previewText.hasPrefix("Hello there."))
        #expect(file.title == nil)
        #expect(file.summary == nil)
        #expect(file.transcriptBody == file.body)
    }

    @Test func transcriptBodyRendersInlineMarkdownNatively() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TFTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("t.md")
        try """
        ---
        date: 2026-03-14T09:15:30-04:00
        backend: deepgram
        ---

        ## Transcript

        **Alice:** Hello there.
        **Bob:** Hi Alice.
        """.write(to: url, atomically: true, encoding: .utf8)

        let file = try #require(TranscriptFile.parse(url: url))
        let attributed = file.transcriptBodyAttributed
        let plain = String(attributed.characters)

        // Markdown emphasis is consumed into styling, never shown literally as `**`.
        #expect(plain.contains("Alice: Hello there."))
        #expect(plain.contains("Bob: Hi Alice."))
        #expect(!plain.contains("**"))
        // The bold speaker labels produce a strong-emphasis run (native markdown styling).
        #expect(attributed.runs.contains {
            $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
        })
        // `.inlineOnlyPreservingWhitespace` keeps the line break between the two turns.
        #expect(plain.contains("\n"))
    }

    // A large transcript can't render as one `Text` — it exceeds CoreText's single-layout
    // ceiling (draws blank) and forces a synchronous full-document markdown parse on open.
    // `transcriptBlocks` splits the body into render units small enough to lay out lazily.

    @Test func transcriptBlocksSplitsEachSpeakerTurn() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TFTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("t.md")
        // Deepgram writes each diarized turn as its own blank-line-separated paragraph.
        try """
        ---
        date: 2026-03-14T09:15:30-04:00
        backend: deepgram
        ---

        ## Transcript

        **Speaker 0:** First turn text.

        **Speaker 1:** Second turn text.

        **Speaker 0:** Third turn text.
        """.write(to: url, atomically: true, encoding: .utf8)

        let file = try #require(TranscriptFile.parse(url: url))
        let blocks = file.transcriptBlocks
        #expect(blocks.count == 3)
        #expect(blocks[0].text == "**Speaker 0:** First turn text.")
        #expect(blocks[2].text == "**Speaker 0:** Third turn text.")
        // Ids are stable and unique so `ForEach` identity holds across re-renders.
        #expect(Set(blocks.map(\.id)).count == blocks.count)
    }

    @Test func transcriptBlocksSubsplitsOversizedParagraphWithoutLosingWords() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TFTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("t.md")
        // On-device backends emit the whole transcript as one long paragraph — the case that
        // blanks a single `Text`. Unique words let us assert nothing is dropped or reordered.
        let words = (0..<4000).map { "w\($0)" }
        let paragraph = words.joined(separator: " ")
        #expect(paragraph.count > TranscriptFile.maxBlockCharacters)
        try """
        ---
        date: 2026-03-14T09:15:30-04:00
        backend: speechAnalyzer
        ---

        ## Transcript

        \(paragraph)
        """.write(to: url, atomically: true, encoding: .utf8)

        let file = try #require(TranscriptFile.parse(url: url))
        let blocks = file.transcriptBlocks
        // The one giant paragraph is broken into several within-cap blocks.
        #expect(blocks.count > 1)
        #expect(blocks.allSatisfy { $0.text.count <= TranscriptFile.maxBlockCharacters })
        // Reassembling the blocks reproduces every word, in order — no data loss.
        let roundTrip = blocks.flatMap { $0.text.split(whereSeparator: \.isWhitespace).map(String.init) }
        #expect(roundTrip == words)
    }

    @Test func transcriptBlocksKeepsAShortBodyWhole() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TFTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("t.md")
        try """
        ---
        date: 2026-03-14T09:15:30-04:00
        backend: speechAnalyzer
        ---

        ## Transcript

        Hello there. Short body.
        """.write(to: url, atomically: true, encoding: .utf8)

        let file = try #require(TranscriptFile.parse(url: url))
        let blocks = file.transcriptBlocks
        #expect(blocks.count == 1)
        #expect(blocks[0].text == "Hello there. Short body.")
    }

    // Head+tail excerpt disclaimer (2026-07-14): the writer appends a markdown-italic
    // disclaimer line to the Summary section of an excerpted long transcript. The in-app
    // summary is rendered with a verbatim `Text(String)`, which does NOT interpret markdown,
    // so the `_..._` would show as literal underscores. The parser therefore lifts the
    // disclaimer out of `summary` (rendered separately, styled) and flags it via
    // `summaryIsExcerpt`, keeping the untrusted model summary verbatim.

    private func parseFile(_ contents: String) throws -> TranscriptFile {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TFTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("t.md")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return try #require(TranscriptFile.parse(url: url))
    }

    private func excerptedSummaryMarkdown() -> String {
        """
        ---
        date: 2026-03-14T09:15:30-04:00
        backend: speechAnalyzer
        title: Long sync
        ---

        # Long sync — 9:15 AM

        ## Summary

        Quick status sync about the beta.

        Action items:
        - File compliance

        \(TranscriptMarkdownWriter.excerptDisclaimer)

        ## Transcript

        We synced on the rollout and the beta numbers.
        """
    }

    @Test func excerptDisclaimerIsStrippedFromSummary() throws {
        let file = try parseFile(excerptedSummaryMarkdown())
        let summary = try #require(file.summary)
        // The model's summary prose and action items remain part of the summary section…
        #expect(summary.contains("Quick status sync about the beta."))
        #expect(summary.contains("File compliance"))
        // …but the trusted disclaimer is lifted out, so no literal markdown underscores or
        // disclaimer wording leak into the verbatim-rendered summary body.
        #expect(!summary.contains("based on excerpts of the transcript"))
        #expect(!summary.contains("_"))
    }

    @Test func excerptedSummaryIsFlaggedAsExcerpt() throws {
        let file = try parseFile(excerptedSummaryMarkdown())
        #expect(file.summaryIsExcerpt)
    }

    @Test func completeSummaryIsNotFlaggedAsExcerpt() throws {
        let file = try parseFile(
            """
            ---
            date: 2026-03-14T09:15:30-04:00
            backend: speechAnalyzer
            title: Rollout sync
            ---

            # Rollout sync — 9:15 AM

            ## Summary

            Quick status sync about the beta.

            ## Transcript

            We synced on the rollout.
            """)
        #expect(!file.summaryIsExcerpt)
        #expect(file.summary?.contains("Quick status sync about the beta.") == true)
    }

    @Test func excerptDisclaimerDoesNotLeakIntoPreview() throws {
        let file = try parseFile(excerptedSummaryMarkdown())
        // previewText prefers the summary; with the disclaimer stripped, the home-row snippet
        // (also a verbatim `Text`) never shows the raw `_..._` markdown.
        #expect(!file.previewText.contains("based on excerpts of the transcript"))
        #expect(!file.previewText.contains("_"))
    }
}

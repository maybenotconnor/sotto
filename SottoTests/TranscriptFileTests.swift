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
}

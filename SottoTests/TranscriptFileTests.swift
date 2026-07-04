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
}

import Foundation
import Testing
@testable import Sotto

@MainActor
struct PreviewCacheTests {
    @Test func cachesAndInvalidatesOnModification() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PCTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let md = dir.appendingPathComponent("t.md")
        try "---\nbackend: speechAnalyzer\n---\n\n# Conversation — 9:15 AM\n\nFirst body."
            .write(to: md, atomically: true, encoding: .utf8)

        let cache = PreviewCache()
        #expect(cache.preview(for: md)?.hasPrefix("First body") == true)

        // Rewrite with a NEWER mtime → cache must re-parse.
        try "---\nbackend: speechAnalyzer\n---\n\n# Conversation — 9:15 AM\n\nSecond body."
            .write(to: md, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: md.path)
        #expect(cache.preview(for: md)?.hasPrefix("Second body") == true)

        #expect(cache.preview(for: dir.appendingPathComponent("missing.md")) == nil)
    }
}

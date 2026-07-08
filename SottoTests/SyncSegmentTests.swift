import Foundation
import Testing
@testable import Sotto

struct SyncSegmentTests {
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SyncSegment-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func derivesDayBasenameMarkdownFromM4A() {
        let root = tempDir()
        let m4a = root.appendingPathComponent("2026-07-05/09-15-00.m4a")

        let segment = SyncSegment(m4aURL: m4a)

        #expect(segment.day == "2026-07-05")
        #expect(segment.basename == "09-15-00")
        #expect(segment.markdown.lastPathComponent == "09-15-00.md")
    }

    @Test func audioPresentOnlyWhenFileExists() throws {
        let root = tempDir()
        let dayDir = root.appendingPathComponent("2026-07-05", isDirectory: true)
        try FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)
        let m4a = dayDir.appendingPathComponent("09-15-00.m4a")

        #expect(SyncSegment(m4aURL: m4a).audio == nil)   // retention deleted it → nil
        try Data([0x01]).write(to: m4a)
        #expect(SyncSegment(m4aURL: m4a).audio == m4a)   // kept → present
    }
}

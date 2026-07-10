import Foundation
import Testing
@testable import Sotto

struct CoordinatedMirrorTests {
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CoordinatedMirror-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeFile(_ text: String, at url: URL) {
        try! FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! text.write(to: url, atomically: true, encoding: .utf8)
    }

    @Test func copyCreatesDayDirAndCopies() {
        let src = tempDir(), dest = tempDir()
        let source = src.appendingPathComponent("09-15-00.md")
        writeFile("body", at: source)

        let ok = CoordinatedMirror.copy(source, day: "2026-07-05", into: dest)

        #expect(ok == true)
        #expect(FileManager.default.fileExists(
            atPath: dest.appendingPathComponent("2026-07-05/09-15-00.md").path))
    }

    @Test func copyReplacesExisting() throws {
        let src = tempDir(), dest = tempDir()
        let source = src.appendingPathComponent("09-15-00.md")
        writeFile("v1", at: source)
        CoordinatedMirror.copy(source, day: "2026-07-05", into: dest)
        writeFile("v2", at: source)

        CoordinatedMirror.copy(source, day: "2026-07-05", into: dest)

        let landed = dest.appendingPathComponent("2026-07-05/09-15-00.md")
        #expect(try String(contentsOf: landed, encoding: .utf8) == "v2")
    }

    @Test func copyOfMissingSourceReturnsFalse() {
        let dest = tempDir()
        let missing = tempDir().appendingPathComponent("nope.md")
        #expect(CoordinatedMirror.copy(missing, day: "2026-07-05", into: dest) == false)
    }

    /// Regression: the M11 folder-sync data loss. The system file picker defaulted to the
    /// app's OWN store, so the mirror destination overlapped the source — `copyReplacing`'s
    /// remove-then-copy then deleted each transcript in place (removeItem(target) where
    /// target == source, then a failing copy). Mirroring a file into a destination that
    /// resolves to its own directory must leave the file completely intact.
    @Test func copyIntoOwnDirectoryNeverDeletesTheSource() throws {
        let root = tempDir()
        let day = "2026-07-05"
        let source = root.appendingPathComponent("\(day)/09-15-00.md")
        writeFile("irreplaceable transcript", at: source)

        // Destination == the source's own store root ⇒ dayDir == the source's directory
        // ⇒ target resolves to `source` itself.
        let ok = CoordinatedMirror.copy(source, day: day, into: root)

        #expect(ok == false)   // nothing to mirror when source and target are the same file
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(try String(contentsOf: source, encoding: .utf8) == "irreplaceable transcript")
    }

    @Test func removeDeletesNamedFilesAndToleratesAbsence() {
        let src = tempDir(), dest = tempDir()
        let source = src.appendingPathComponent("09-15-00.md")
        writeFile("body", at: source)
        CoordinatedMirror.copy(source, day: "2026-07-05", into: dest)
        let landed = dest.appendingPathComponent("2026-07-05/09-15-00.md")
        #expect(FileManager.default.fileExists(atPath: landed.path))

        CoordinatedMirror.remove(["09-15-00.md"], day: "2026-07-05", from: dest)
        #expect(!FileManager.default.fileExists(atPath: landed.path))

        // Second remove of the now-absent file: silent no-op, never a crash.
        CoordinatedMirror.remove(["09-15-00.md"], day: "2026-07-05", from: dest)
    }
}

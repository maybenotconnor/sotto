import Foundation
import Testing
@testable import Sotto

struct ICloudRestoreTests {
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ICloudRestore-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A minimal valid transcript with parseable frontmatter so DayIndexRebuilder indexes it.
    private func transcriptBody(date: String) -> String {
        """
        ---
        date: \(date)
        duration: 12.0
        backend: speechAnalyzer
        title: Restored chat
        ---

        **Speaker 0:** hello there
        """
    }

    /// Writes `<container>/Transcripts/<day>/<base>.md`.
    private func seedContainer(_ container: URL, day: String, base: String, iso: String) throws {
        let dir = container.appendingPathComponent("Transcripts/\(day)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try transcriptBody(date: iso).write(
            to: dir.appendingPathComponent("\(base).md"), atomically: true, encoding: .utf8)
    }

    @Test func restoresMissingTranscriptAndRebuildsIndex() async throws {
        let local = tempDir(), container = tempDir()
        try seedContainer(container, day: "2026-07-05", base: "09-15-00", iso: "2026-07-05T09:15:00Z")
        let dayIndex = DayIndexStore(rootDirectory: local)

        let restored = await ICloudRestore.run(localRoot: local, containerRoot: container, dayIndex: dayIndex)

        #expect(restored == 1)
        #expect(FileManager.default.fileExists(
            atPath: local.appendingPathComponent("2026-07-05/09-15-00.md").path))
        // _day.json rebuilt from the restored .md, with hasAudio false (audio is never backed up).
        let index = await dayIndex.index(forDay: local.appendingPathComponent("2026-07-05"))
        #expect(index?.segments.count == 1)
        #expect(index?.segments.first?.hasAudio == false)
        #expect(index?.segments.first?.transcriptionState == "done")
    }

    @Test func neverOverwritesAnExistingLocalTranscript() async throws {
        let local = tempDir(), container = tempDir()
        try seedContainer(container, day: "2026-07-05", base: "09-15-00", iso: "2026-07-05T09:15:00Z")
        let localDay = local.appendingPathComponent("2026-07-05", isDirectory: true)
        try FileManager.default.createDirectory(at: localDay, withIntermediateDirectories: true)
        try "LOCAL WINS".write(
            to: localDay.appendingPathComponent("09-15-00.md"), atomically: true, encoding: .utf8)
        let dayIndex = DayIndexStore(rootDirectory: local)

        let restored = await ICloudRestore.run(localRoot: local, containerRoot: container, dayIndex: dayIndex)

        #expect(restored == 0)
        #expect(try String(contentsOf: localDay.appendingPathComponent("09-15-00.md"), encoding: .utf8) == "LOCAL WINS")
    }

    @Test func idempotentAcrossTwoRuns() async throws {
        let local = tempDir(), container = tempDir()
        try seedContainer(container, day: "2026-07-05", base: "09-15-00", iso: "2026-07-05T09:15:00Z")
        let dayIndex = DayIndexStore(rootDirectory: local)

        let first = await ICloudRestore.run(localRoot: local, containerRoot: container, dayIndex: dayIndex)
        let second = await ICloudRestore.run(localRoot: local, containerRoot: container, dayIndex: dayIndex)

        #expect(first == 1)
        #expect(second == 0)   // nothing new the second time
    }

    @Test func emptyContainerRestoresNothing() async throws {
        let local = tempDir(), container = tempDir()
        let dayIndex = DayIndexStore(rootDirectory: local)
        #expect(await ICloudRestore.run(localRoot: local, containerRoot: container, dayIndex: dayIndex) == 0)
    }
}

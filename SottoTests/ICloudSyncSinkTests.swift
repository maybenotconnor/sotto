import Foundation
import Testing
@testable import Sotto

struct ICloudSyncSinkTests {
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ICloudSyncSink-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// `<localRoot>/<day>/<name>.md [+ .m4a]`; returns the m4a URL (created iff `m4a`).
    @discardableResult
    private func makeSegment(
        root: URL, day: String, name: String, md: String? = "transcript", m4a: Bool = true
    ) throws -> URL {
        let dayDir = root.appendingPathComponent(day, isDirectory: true)
        try FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)
        let m4aURL = dayDir.appendingPathComponent("\(name).m4a")
        if m4a { try Data([0x01]).write(to: m4aURL) }
        if let md {
            try md.write(to: dayDir.appendingPathComponent("\(name).md"),
                         atomically: true, encoding: .utf8)
        }
        return m4aURL
    }

    private func sink(container: URL) -> ICloudSyncSink {
        ICloudSyncSink(resolveContainer: { container })
    }

    private func transcript(_ container: URL, _ day: String, _ base: String) -> URL {
        container.appendingPathComponent("Transcripts/\(day)/\(base).md")
    }

    @Test func upsertCopiesMarkdownOnlyIntoTranscriptsPrefix() async throws {
        let local = tempDir(), container = tempDir()
        let m4a = try makeSegment(root: local, day: "2026-07-05", name: "09-15-00")

        await sink(container: container).upsert(SyncSegment(m4aURL: m4a))

        #expect(FileManager.default.fileExists(atPath: transcript(container, "2026-07-05", "09-15-00").path))
        // Audio is NEVER backed up to iCloud (quota + privacy).
        #expect(!FileManager.default.fileExists(
            atPath: container.appendingPathComponent("Transcripts/2026-07-05/09-15-00.m4a").path))
    }

    @Test func upsertOverwritesExistingTranscript() async throws {
        let local = tempDir(), container = tempDir()
        let m4a = try makeSegment(root: local, day: "2026-07-05", name: "11-00-00", md: "v1")
        let s = sink(container: container)
        await s.upsert(SyncSegment(m4aURL: m4a))
        try "v2".write(to: m4a.deletingPathExtension().appendingPathExtension("md"),
                       atomically: true, encoding: .utf8)

        await s.upsert(SyncSegment(m4aURL: m4a))

        #expect(try String(contentsOf: transcript(container, "2026-07-05", "11-00-00"), encoding: .utf8) == "v2")
    }

    @Test func removeDeletesTranscriptAndToleratesAbsence() async throws {
        let local = tempDir(), container = tempDir()
        let m4a = try makeSegment(root: local, day: "2026-03-14", name: "09-15-30")
        let s = sink(container: container)
        await s.upsert(SyncSegment(m4aURL: m4a))
        #expect(FileManager.default.fileExists(atPath: transcript(container, "2026-03-14", "09-15-30").path))

        await s.remove(day: "2026-03-14", basename: "09-15-30")
        #expect(!FileManager.default.fileExists(atPath: transcript(container, "2026-03-14", "09-15-30").path))

        await s.remove(day: "2026-03-14", basename: "09-15-30")   // second remove: no-op, no crash
    }

    @Test func backupAllSweepsEveryDayMarkdownAndSkipsInternalFiles() async throws {
        let local = tempDir(), container = tempDir()
        try makeSegment(root: local, day: "2026-07-04", name: "08-00-00")             // md + m4a
        try makeSegment(root: local, day: "2026-07-05", name: "09-00-00", m4a: false) // md only
        try Data([1]).write(to: local.appendingPathComponent("2026-07-04/_day.json"))
        try Data([1]).write(to: local.appendingPathComponent("2026-07-04/08-30-00.caf"))

        let copied = await sink(container: container).backupAll(localRoot: local)

        #expect(copied == 2)   // 2 × .md only — never .m4a / _day.json / .caf
        #expect(FileManager.default.fileExists(atPath: transcript(container, "2026-07-04", "08-00-00").path))
        #expect(FileManager.default.fileExists(atPath: transcript(container, "2026-07-05", "09-00-00").path))
        #expect(!FileManager.default.fileExists(
            atPath: container.appendingPathComponent("Transcripts/2026-07-04/08-00-00.m4a").path))
    }

    @Test func removeAllBackupsClearsThePrefixAndHasBackupsTracksIt() async throws {
        let local = tempDir(), container = tempDir()
        let m4a = try makeSegment(root: local, day: "2026-07-05", name: "09-15-00")
        let s = sink(container: container)
        #expect(await s.hasBackups() == false)
        await s.upsert(SyncSegment(m4aURL: m4a))
        #expect(await s.hasBackups() == true)

        await s.removeAllBackups()
        #expect(await s.hasBackups() == false)
    }

    @Test func unavailableContainerMakesEveryOpANoOp() async throws {
        let local = tempDir()
        let m4a = try makeSegment(root: local, day: "2026-07-05", name: "09-15-00")
        let s = ICloudSyncSink(resolveContainer: { nil })   // signed out / no entitlement

        await s.upsert(SyncSegment(m4aURL: m4a))    // no crash, nothing to assert but no throw
        await s.remove(day: "2026-07-05", basename: "09-15-00")
        #expect(await s.backupAll(localRoot: local) == 0)
        #expect(await s.hasBackups() == false)
        await s.removeAllBackups()
    }
}

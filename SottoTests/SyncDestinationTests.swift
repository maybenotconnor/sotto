import Foundation
import Testing
@testable import Sotto

struct SyncDestinationTests {
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SyncDestinationTests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func freshSuite() -> UserDefaults {
        UserDefaults(suiteName: "sync-destination-tests-\(UUID().uuidString)")!
    }

    @Test func storeRoundTripsAFolderBookmark() throws {
        let suite = freshSuite()
        let store = SyncDestinationStore(defaults: suite)
        #expect(store.isConfigured == false)
        #expect(store.resolve() == nil)
        #expect(store.displayName == nil)

        let folder = tempDir()
        try store.save(url: folder)
        #expect(store.isConfigured == true)
        #expect(store.displayName == folder.lastPathComponent)
        #expect(store.resolve()?.standardizedFileURL.path == folder.standardizedFileURL.path)
    }

    @Test func clearRemovesTheDestination() throws {
        let suite = freshSuite()
        let store = SyncDestinationStore(defaults: suite)
        try store.save(url: tempDir())
        store.clear()
        #expect(store.isConfigured == false)
        #expect(store.resolve() == nil)
        #expect(store.displayName == nil)
    }

    @Test func resolveReturnsNilWhenTheFolderIsGone() throws {
        let suite = freshSuite()
        let store = SyncDestinationStore(defaults: suite)
        let folder = tempDir()
        try store.save(url: folder)
        try FileManager.default.removeItem(at: folder)
        #expect(store.resolve() == nil)   // deleted folder → unresolvable, not a crash
    }

    /// Builds `<root>/<day>/<name>.md [+ .m4a]` and returns the m4a URL (even if not created).
    private func makeSegment(
        root: URL, day: String, name: String, md: String? = "transcript", m4a: Bool = true
    ) throws -> URL {
        let dayDir = root.appendingPathComponent(day, isDirectory: true)
        try FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)
        let m4aURL = dayDir.appendingPathComponent("\(name).m4a")
        if m4a { try Data([0x01]).write(to: m4aURL) }
        if let md {
            try md.write(
                to: dayDir.appendingPathComponent("\(name).md"), atomically: true, encoding: .utf8)
        }
        return m4aURL
    }

    @Test func exportMirrorsTheDayLayout() throws {
        let root = tempDir(), dest = tempDir()
        let m4a = try makeSegment(root: root, day: "2026-07-05", name: "09-15-00")

        let exported = SegmentExporter.export(m4aURL: m4a, to: dest)

        #expect(exported == SegmentExporter.Exported(markdown: true, audio: true))
        let day = dest.appendingPathComponent("2026-07-05")
        #expect(FileManager.default.fileExists(atPath: day.appendingPathComponent("09-15-00.md").path))
        #expect(FileManager.default.fileExists(atPath: day.appendingPathComponent("09-15-00.m4a").path))
    }

    @Test func exportCopiesTranscriptOnlyWhenAudioWasDeleted() throws {
        // deleteAfterTranscription retention removes the m4a before export runs — the
        // transcript must still make it to the cloud, reported honestly.
        let root = tempDir(), dest = tempDir()
        let m4a = try makeSegment(root: root, day: "2026-07-05", name: "10-00-00", m4a: false)

        let exported = SegmentExporter.export(m4aURL: m4a, to: dest)

        #expect(exported == SegmentExporter.Exported(markdown: true, audio: false))
        let day = dest.appendingPathComponent("2026-07-05")
        #expect(FileManager.default.fileExists(atPath: day.appendingPathComponent("10-00-00.md").path))
        #expect(!FileManager.default.fileExists(atPath: day.appendingPathComponent("10-00-00.m4a").path))
    }

    @Test func reExportOverwritesTheOldTranscript() throws {
        // Re-transcription rewrites the local .md; a second export must replace, not fail on,
        // the existing destination copy.
        let root = tempDir(), dest = tempDir()
        let m4a = try makeSegment(root: root, day: "2026-07-05", name: "11-00-00", md: "v1")
        SegmentExporter.export(m4aURL: m4a, to: dest)
        try "v2".write(
            to: m4a.deletingPathExtension().appendingPathExtension("md"),
            atomically: true, encoding: .utf8)

        let exported = SegmentExporter.export(m4aURL: m4a, to: dest)

        #expect(exported.markdown == true)
        let copied = dest.appendingPathComponent("2026-07-05/11-00-00.md")
        #expect(try String(contentsOf: copied, encoding: .utf8) == "v2")
    }

    @Test func exportAllSweepsEveryDayAndSkipsInternalFiles() throws {
        let root = tempDir(), dest = tempDir()
        _ = try makeSegment(root: root, day: "2026-07-04", name: "08-00-00")               // md + m4a
        _ = try makeSegment(root: root, day: "2026-07-05", name: "09-00-00", m4a: false)   // md only
        // Internal files that must NOT be exported:
        try Data([1]).write(to: root.appendingPathComponent("2026-07-04/_day.json"))
        try Data([1]).write(to: root.appendingPathComponent("2026-07-04/08-30-00.caf"))

        let copied = SegmentExporter.exportAll(root: root, to: dest)

        #expect(copied == 3)   // 2×md + 1×m4a
        #expect(FileManager.default.fileExists(
            atPath: dest.appendingPathComponent("2026-07-04/08-00-00.m4a").path))
        #expect(FileManager.default.fileExists(
            atPath: dest.appendingPathComponent("2026-07-05/09-00-00.md").path))
        #expect(!FileManager.default.fileExists(
            atPath: dest.appendingPathComponent("2026-07-04/_day.json").path))
        #expect(!FileManager.default.fileExists(
            atPath: dest.appendingPathComponent("2026-07-04/08-30-00.caf").path))
    }

    @Test func removeDeletesMirroredPairAndToleratesAbsence() throws {
        let local = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoveTests-\(UUID().uuidString)")
        let day = local.appendingPathComponent("2026-03-14", isDirectory: true)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let m4aURL = day.appendingPathComponent("09-15-30.m4a")
        try Data([0x01]).write(to: m4aURL)
        try "body".write(
            to: day.appendingPathComponent("09-15-30.md"), atomically: true, encoding: .utf8)
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoveDest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        SegmentExporter.export(m4aURL: m4aURL, to: destination)
        let mirroredMD = destination.appendingPathComponent("2026-03-14/09-15-30.md")
        #expect(FileManager.default.fileExists(atPath: mirroredMD.path))

        SegmentExporter.remove(m4aURL: m4aURL, from: destination)

        #expect(!FileManager.default.fileExists(atPath: mirroredMD.path))
        #expect(!FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("2026-03-14/09-15-30.m4a").path))

        // Second remove of the now-absent pair: silent no-op, never a crash/throw.
        SegmentExporter.remove(m4aURL: m4aURL, from: destination)
    }
}

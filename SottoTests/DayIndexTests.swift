import Foundation
import Testing
@testable import Sotto

struct DayIndexTests {
    private func tempRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("DayIndexTests-\(UUID().uuidString)")
    }

    private func m4a(_ root: URL, day: String, name: String) -> URL {
        let dir = root.appendingPathComponent(day, isDirectory: true)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(name).m4a")
    }

    @Test func recordsSortsAndPersistsSegments() async throws {
        let root = tempRoot()
        let store = DayIndexStore(rootDirectory: root)
        let later = m4a(root, day: "2026-03-14", name: "10-42-18")
        let earlier = m4a(root, day: "2026-03-14", name: "09-15-30")

        await store.recordQueuedSegment(
            m4aURL: later, startTime: Date(timeIntervalSince1970: 2_000), duration: 60)
        await store.recordQueuedSegment(
            m4aURL: earlier, startTime: Date(timeIntervalSince1970: 1_000), duration: 342)

        let index = await store.index(forDay: later.deletingLastPathComponent())
        #expect(index?.date == "2026-03-14")
        #expect(index?.segments.map(\.id) == ["09-15-30", "10-42-18"])   // sorted by startTime
        #expect(index?.segments[0].transcriptionState == "queued")
        #expect(index?.segments[0].hasAudio == true)
        // Atomic file actually exists:
        #expect(FileManager.default.fileExists(
            atPath: later.deletingLastPathComponent().appendingPathComponent("_day.json").path))
    }

    @Test func startTimeIsWrittenAsISO8601String() async throws {
        let root = tempRoot()
        let store = DayIndexStore(rootDirectory: root)
        let url = m4a(root, day: "2026-03-14", name: "09-15-30")
        await store.recordQueuedSegment(
            m4aURL: url, startTime: Date(timeIntervalSince1970: 1_771_053_330), duration: 10)

        let jsonURL = url.deletingLastPathComponent().appendingPathComponent("_day.json")
        let raw = try String(contentsOf: jsonURL, encoding: .utf8)
        // ISO8601 string starting with the year, not a raw epoch number.
        #expect(raw.contains("\"startTime\" : \"2") || raw.contains("\"startTime\":\"2"))
    }

    @Test func updateAndAudioRemovalMutateTheRightEntry() async throws {
        let root = tempRoot()
        let store = DayIndexStore(rootDirectory: root)
        let url = m4a(root, day: "2026-03-14", name: "09-15-30")
        await store.recordQueuedSegment(m4aURL: url, startTime: Date(), duration: 10)

        await store.updateSegment(
            m4aURL: url, transcriptionState: "done", backend: "speechAnalyzer", wordCount: 847,
            title: "Rollout sync")
        await store.setAudioRemoved(m4aURL: url)

        let entry = await store.index(forDay: url.deletingLastPathComponent())?.segments.first
        #expect(entry?.transcriptionState == "done")
        #expect(entry?.backend == "speechAnalyzer")
        #expect(entry?.wordCount == 847)
        #expect(entry?.hasAudio == false)
        #expect(entry?.title == "Rollout sync")
    }

    @Test func setTitleMutatesOnlyTheTitle() async throws {
        let root = tempRoot()
        let store = DayIndexStore(rootDirectory: root)
        let url = m4a(root, day: "2026-03-14", name: "09-15-30")
        await store.recordQueuedSegment(m4aURL: url, startTime: Date(), duration: 10)
        await store.updateSegment(
            m4aURL: url, transcriptionState: "done", backend: "speechAnalyzer", wordCount: 847,
            title: "Rollout sync")

        await store.setTitle(m4aURL: url, title: "Rollout retro")

        let entry = await store.index(forDay: url.deletingLastPathComponent())?.segments.first
        #expect(entry?.title == "Rollout retro")
        // Everything else untouched.
        #expect(entry?.transcriptionState == "done")
        #expect(entry?.backend == "speechAnalyzer")
        #expect(entry?.wordCount == 847)
        #expect(entry?.hasAudio == true)
    }

    @Test func reRecordingSameIdReplacesNotDuplicates() async throws {
        let root = tempRoot()
        let store = DayIndexStore(rootDirectory: root)
        let url = m4a(root, day: "2026-03-14", name: "09-15-30")
        await store.recordQueuedSegment(m4aURL: url, startTime: Date(), duration: 10)
        await store.recordQueuedSegment(m4aURL: url, startTime: Date(), duration: 12)
        let index = await store.index(forDay: url.deletingLastPathComponent())
        #expect(index?.segments.count == 1)
        #expect(index?.segments[0].duration == 12)
    }

    @Test func gapsRecordOnTheirLocalDayEvenWithNoSegments() async throws {
        let root = tempRoot()
        let store = DayIndexStore(rootDirectory: root)
        let when = Date()
        await store.recordGap(onDayOf: when, from: when, reason: "uncleanShutdown")

        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.calendar = Calendar(identifier: .gregorian)
        dayFormatter.dateFormat = "yyyy-MM-dd"
        let dayDir = root.appendingPathComponent(dayFormatter.string(from: when))
        let index = await store.index(forDay: dayDir)
        #expect(index?.gaps.count == 1)
        #expect(index?.gaps[0].reason == "uncleanShutdown")
        #expect(index?.segments.isEmpty == true)
    }

    @Test func corruptIndexLoadsAsNil() async throws {
        let root = tempRoot()
        let store = DayIndexStore(rootDirectory: root)
        let dir = root.appendingPathComponent("2026-03-14")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data([0x7b, 0x00]).write(to: dir.appendingPathComponent("_day.json"))
        #expect(await store.index(forDay: dir) == nil)
    }

    @Test func corruptIndexIsRebuiltFromFilesOnNextWrite() async throws {
        let root = tempRoot()
        let store = DayIndexStore(rootDirectory: root)
        let existing = m4a(root, day: "2026-03-14", name: "08-00-00")
        try Data([0x01]).write(to: existing)                       // pre-existing audio on disk
        let dir = existing.deletingLastPathComponent()
        try Data([0x7b, 0x00]).write(to: dir.appendingPathComponent("_day.json"))   // corrupt

        let newSegment = m4a(root, day: "2026-03-14", name: "09-15-30")
        await store.recordQueuedSegment(m4aURL: newSegment, startTime: Date(), duration: 5)

        let index = await store.index(forDay: dir)
        #expect(index?.segments.count == 2)                        // rebuilt 08-00-00 + new one
        #expect(index?.segments.contains { $0.id == "08-00-00" } == true)
    }

    @Test func rebuildAndPersistWritesTheRebuiltIndexToDisk() async throws {
        let root = tempRoot()
        let store = DayIndexStore(rootDirectory: root)
        let existing = m4a(root, day: "2026-03-14", name: "08-00-00")
        let dir = existing.deletingLastPathComponent()
        let md = """
        ---
        date: 2026-03-14T08:00:00-04:00
        duration: 12
        backend: speechAnalyzer
        ---

        Hello world.
        """
        try md.write(to: dir.appendingPathComponent("08-00-00.md"), atomically: true, encoding: .utf8)
        try Data([0x01]).write(to: existing)
        try Data([0x7b, 0x00]).write(to: dir.appendingPathComponent("_day.json"))   // corrupt

        let rebuilt = await store.rebuildAndPersist(dayDirectory: dir)
        #expect(rebuilt.segments.count == 1)
        #expect(rebuilt.segments.first?.id == "08-00-00")

        // The corrupt file was replaced — a plain load now succeeds and matches.
        let reloaded = await store.index(forDay: dir)
        #expect(reloaded?.segments.count == 1)
        #expect(reloaded?.segments.first?.id == "08-00-00")
        #expect(reloaded?.segments.first?.transcriptionState == "done")
    }

    @Test func rebuildsIndexFromMarkdownAndOrphanAudio() async throws {
        let root = tempRoot()
        let dir = root.appendingPathComponent("2026-03-14")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // A transcribed segment: .md (spec frontmatter) + .m4a
        let md = """
        ---
        date: 2026-03-14T09:15:30-04:00
        duration: 342
        speechEnd: 2026-03-14T09:20:12-04:00
        backend: speechAnalyzer
        title: Rollout sync
        ---

        # Rollout sync — 9:15 AM

        Hello there general conversation words here.
        """
        try md.write(to: dir.appendingPathComponent("09-15-30.md"), atomically: true, encoding: .utf8)
        try Data([0x01]).write(to: dir.appendingPathComponent("09-15-30.m4a"))
        // An untranscribed segment: audio only
        try Data([0x01]).write(to: dir.appendingPathComponent("10-42-18.m4a"))

        let index = DayIndexRebuilder.rebuild(dayDirectory: dir)

        #expect(index.date == "2026-03-14")
        #expect(index.segments.count == 2)
        let done = index.segments.first { $0.id == "09-15-30" }
        #expect(done?.transcriptionState == "done")
        #expect(done?.backend == "speechAnalyzer")
        #expect(done?.duration == 342)
        #expect(done?.hasAudio == true)
        #expect((done?.wordCount ?? 0) >= 6)                 // body words counted
        #expect(done?.title == "Rollout sync")
        let queued = index.segments.first { $0.id == "10-42-18" }
        #expect(queued?.transcriptionState == "queued")
        #expect(queued?.wordCount == nil)
        // Sorted by startTime:
        #expect(index.segments.map(\.id) == ["09-15-30", "10-42-18"])
    }

    @Test func unreadableMarkdownDegradesToQueuedEntry() async throws {
        let root = tempRoot()
        let dir = root.appendingPathComponent("2026-03-14")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Garbage non-UTF8 bytes: unparseable as a String, must not suppress the m4a fallback.
        try Data([0xFF, 0xFE, 0x00, 0xFF]).write(to: dir.appendingPathComponent("11-00-00.md"))
        try Data([0x01]).write(to: dir.appendingPathComponent("11-00-00.m4a"))

        let index = DayIndexRebuilder.rebuild(dayDirectory: dir)

        let entry = index.segments.first { $0.id == "11-00-00" }
        #expect(entry != nil)
        #expect(entry?.transcriptionState == "queued")
    }

    @Test func wordCountExcludesSpeakerLabels() async throws {
        let root = tempRoot()
        let dir = root.appendingPathComponent("2026-03-14")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let md = """
        ---
        date: 2026-03-14T11:00:00-04:00
        duration: 42
        backend: deepgram
        ---

        **Speaker 1:** Hello there, this is a test.
        **Speaker 2:** Yes it certainly is indeed.
        """
        try md.write(to: dir.appendingPathComponent("11-00-00.md"), atomically: true, encoding: .utf8)

        let index = DayIndexRebuilder.rebuild(dayDirectory: dir)

        let entry = index.segments.first { $0.id == "11-00-00" }
        #expect(entry?.wordCount == 11)   // speaker labels excluded from the count
    }

    @Test func removeSegmentDropsEntry() async throws {
        let root = tempRoot()
        let store = DayIndexStore(rootDirectory: root)
        let url = m4a(root, day: "2026-03-14", name: "09-15-30")
        await store.recordQueuedSegment(m4aURL: url, startTime: Date(), duration: 5)
        await store.removeSegment(m4aURL: url)
        #expect(await store.index(forDay: url.deletingLastPathComponent())?.segments.isEmpty == true)
    }
}

@Suite struct DayIndexMergeTests {
    private func makeDay(_ files: [(id: String, markdown: String)]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("IndexMergeTests-\(UUID().uuidString)")
            .appendingPathComponent("2026-03-14", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for file in files {
            try file.markdown.write(
                to: dir.appendingPathComponent("\(file.id).md"),
                atomically: true, encoding: .utf8)
        }
        return dir
    }

    @Test func applyMergeReplacesPartEntriesWithMergedEntry() async throws {
        let dir = try makeDay([
            ("09-15-30", ConversationMergerTests.partOne),
            ("10-01-00", ConversationMergerTests.partTwo),
        ])
        let store = DayIndexStore(rootDirectory: dir.deletingLastPathComponent())
        let entries = DayIndexRebuilder.rebuild(dayDirectory: dir).segments
        let outcome = try await ConversationMerger.merge(dayDirectory: dir, entries: entries)

        await store.applyMerge(
            dayDirectory: dir, mergedEntry: outcome.mergedEntry,
            removedIDs: outcome.removedIDs)

        let index = try #require(await store.index(forDay: dir))
        #expect(index.segments.count == 1)
        #expect(index.segments[0] == outcome.mergedEntry)
    }

    /// The spec's rebuild-parity invariant: after a merge + applyMerge, rebuilding the
    /// index purely from the folder's .md frontmatter must produce the same segments.
    @Test func mergedIndexSurvivesRebuildFromFrontmatter() async throws {
        let dir = try makeDay([
            ("09-15-30", ConversationMergerTests.partOne),
            ("10-01-00", ConversationMergerTests.partTwo),
        ])
        let store = DayIndexStore(rootDirectory: dir.deletingLastPathComponent())
        let entries = DayIndexRebuilder.rebuild(dayDirectory: dir).segments
        let outcome = try await ConversationMerger.merge(dayDirectory: dir, entries: entries)
        await store.applyMerge(
            dayDirectory: dir, mergedEntry: outcome.mergedEntry,
            removedIDs: outcome.removedIDs)

        let stored = try #require(await store.index(forDay: dir))
        let rebuilt = DayIndexRebuilder.rebuild(dayDirectory: dir)

        #expect(rebuilt.segments == stored.segments)
    }

    /// The production-common branch: unlike the two tests above (no `_day.json` on disk,
    /// so `applyMerge` falls back to `DayIndexRebuilder.rebuild`), here the index is
    /// seeded via `recordQueuedSegment` BEFORE the merge runs — exactly how the app itself
    /// gets there (segments are recorded as they're queued). `applyMerge`'s plain
    /// `load(dayDirectory)` must succeed and collapse the two seeded entries into the one
    /// merged entry; a previously-recorded gap must survive untouched.
    @Test func applyMergeCollapsesPreSeededIndexAndPreservesGaps() async throws {
        let dir = try makeDay([
            ("09-15-30", ConversationMergerTests.partOne),
            ("10-01-00", ConversationMergerTests.partTwo),
        ])
        let root = dir.deletingLastPathComponent()
        let store = DayIndexStore(rootDirectory: root)

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let partOneStart = try #require(iso.date(from: "2026-03-14T09:15:30-04:00"))
        let partTwoStart = try #require(iso.date(from: "2026-03-14T10:01:00-04:00"))
        await store.recordQueuedSegment(
            m4aURL: dir.appendingPathComponent("09-15-30.m4a"), startTime: partOneStart,
            duration: 270)
        await store.recordQueuedSegment(
            m4aURL: dir.appendingPathComponent("10-01-00.m4a"), startTime: partTwoStart,
            duration: 120)

        // A gap recorded before the merge, on the same local day as `dir` ("2026-03-14") —
        // built from local date components (not an absolute instant) so it lands in `dir`
        // regardless of the test machine's timezone, matching `recordGap`'s own local-day
        // folder derivation.
        var components = DateComponents()
        components.year = 2026
        components.month = 3
        components.day = 14
        components.hour = 12
        let gapDate = try #require(Calendar.current.date(from: components))
        await store.recordGap(onDayOf: gapDate, from: gapDate, reason: "uncleanShutdown")

        let entries = DayIndexRebuilder.rebuild(dayDirectory: dir).segments
        let outcome = try await ConversationMerger.merge(dayDirectory: dir, entries: entries)
        await store.applyMerge(
            dayDirectory: dir, mergedEntry: outcome.mergedEntry, removedIDs: outcome.removedIDs)

        let index = try #require(await store.index(forDay: dir))
        #expect(index.segments.count == 1)
        #expect(index.segments[0] == outcome.mergedEntry)
        #expect(index.gaps.count == 1)
        #expect(index.gaps[0].reason == "uncleanShutdown")
    }
}

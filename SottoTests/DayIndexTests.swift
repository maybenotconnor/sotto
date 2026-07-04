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

    @Test func updateAndAudioRemovalMutateTheRightEntry() async throws {
        let root = tempRoot()
        let store = DayIndexStore(rootDirectory: root)
        let url = m4a(root, day: "2026-03-14", name: "09-15-30")
        await store.recordQueuedSegment(m4aURL: url, startTime: Date(), duration: 10)

        await store.updateSegment(
            m4aURL: url, transcriptionState: "done", backend: "speechAnalyzer", wordCount: 847)
        await store.setAudioRemoved(m4aURL: url)

        let entry = await store.index(forDay: url.deletingLastPathComponent())?.segments.first
        #expect(entry?.transcriptionState == "done")
        #expect(entry?.backend == "speechAnalyzer")
        #expect(entry?.wordCount == 847)
        #expect(entry?.hasAudio == false)
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
}

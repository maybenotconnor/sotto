import Foundation
import Testing
@testable import Sotto

/// M12 Task 2: `source` threaded FinalizedSegment → TranscriptionJob → markdown frontmatter →
/// `_day.json`. Everything defaults to `.phoneMic` so pre-M12 files/queues/tests stay valid;
/// BINDING: existing markdown output stays byte-identical for phone-mic segments (the
/// `source:` frontmatter line is written ONLY for `.omi`).
struct SourceLabelingTests {
    @Test func audioSourceTypeHasOmiCaseAndDisplayNames() {
        #expect(AudioSourceType.omi.rawValue == "omi")
        #expect(AudioSourceType.phoneMic.displayName == "iPhone mic")
        #expect(AudioSourceType.omi.displayName == "Omi")
    }

    @Test func finalizedSegmentDefaultsToPhoneMic() {
        let seg = FinalizedSegment(
            cafURL: URL(fileURLWithPath: "/tmp/a.caf"), m4aURL: URL(fileURLWithPath: "/tmp/a.m4a"),
            startDate: Date(timeIntervalSince1970: 0), duration: 10, speechDuration: 8)
        #expect(seg.source == .phoneMic)
    }

    @Test func markdownWritesSourceLineOnlyForOmi() throws {
        // Build two jobs via the same construction pattern as MarkdownWriterTests.swift (the
        // real memberwise init: id, cafURL, m4aURL, startDate, duration, speechDuration,
        // attempts, state); the writer must emit `source: omi` for the omi job and NO source
        // line for phoneMic (byte compat).
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let result = TranscriptionResult(
            text: "hello", segments: [], duration: 10, backend: .speechAnalyzer)

        func write(source: AudioSourceType, name: String) throws -> String {
            var job = TranscriptionJob(
                id: UUID(), cafURL: nil, m4aURL: tmp.appendingPathComponent("\(name).m4a"),
                startDate: Date(timeIntervalSince1970: 0),
                duration: 10, speechDuration: 8, attempts: 0, state: .pending)
            job.source = source
            let url = try TranscriptMarkdownWriter.write(result: result, job: job)
            return try String(contentsOf: url, encoding: .utf8)
        }
        let omiMD = try write(source: .omi, name: "omi")
        let micMD = try write(source: .phoneMic, name: "mic")
        #expect(omiMD.contains("\nsource: omi\n"))
        #expect(!micMD.contains("source:"))
    }

    @Test func dayIndexEntryRoundTripsSourceAndDefaultsNil() throws {
        let entry = DaySegmentEntry(
            id: "09-15-30", startTime: Date(timeIntervalSince1970: 0), duration: 10,
            backend: nil, hasAudio: true, wordCount: nil,
            transcriptionState: "queued", title: nil, source: "omi")
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(DaySegmentEntry.self, from: data)
        #expect(decoded.source == "omi")
        // Legacy JSON without the key still decodes, source nil.
        let legacy = """
        {"id":"09-15-30","startTime":0,"duration":10,"hasAudio":true,"transcriptionState":"queued"}
        """.data(using: .utf8)!
        let dec = JSONDecoder()
        let legacyEntry = try dec.decode(DaySegmentEntry.self, from: legacy)
        #expect(legacyEntry.source == nil)
    }

    @Test func queueEnqueueCopiesSegmentSourceOntoJob() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SourceLabelTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let caf = dir.appendingPathComponent("seg.caf")
        let m4a = dir.appendingPathComponent("seg.m4a")
        let writer = try CAFSegmentWriter(cafURL: caf, m4aURL: m4a)
        try writer.append((0..<VADConstants.sampleRate).map { _ in Float(0.1) })
        writer.close()
        var segment = FinalizedSegment(
            cafURL: caf, m4aURL: m4a, startDate: Date(), duration: 1.0, speechDuration: 1.0)
        segment.source = .omi

        let queue = TranscriptionQueue(
            storeURL: dir.appendingPathComponent("jobs.json"),
            service: FakeTranscriptionService(text: "hi"), rootDirectory: dir)
        await queue.enqueue(segment)
        #expect(await queue.jobs.first?.source == .omi)
    }

    @Test func persistedQueueRoundTripsSourceAndDefaultsPhoneMicForLegacyFiles() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SourceLabelTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let caf = dir.appendingPathComponent("seg.caf")
        let m4a = dir.appendingPathComponent("seg.m4a")
        let writer = try CAFSegmentWriter(cafURL: caf, m4aURL: m4a)
        try writer.append((0..<VADConstants.sampleRate).map { _ in Float(0.1) })
        writer.close()
        var segment = FinalizedSegment(
            cafURL: caf, m4aURL: m4a, startDate: Date(), duration: 1.0, speechDuration: 1.0)
        segment.source = .omi

        let store = dir.appendingPathComponent("jobs.json")
        let first = TranscriptionQueue(
            storeURL: store, service: FakeTranscriptionService(text: "hi"), rootDirectory: dir)
        await first.enqueue(segment)

        // Legacy persisted JSON (no "source" key) still loads, defaulting the job to
        // .phoneMic — same decodeIfPresent story as cafPath/m4aPath.
        let legacyStore = dir.appendingPathComponent("legacy-jobs.json")
        let legacyCaf = dir.appendingPathComponent("legacy.caf")
        let legacyM4a = dir.appendingPathComponent("legacy.m4a")
        let legacyWriter = try CAFSegmentWriter(cafURL: legacyCaf, m4aURL: legacyM4a)
        try legacyWriter.append((0..<VADConstants.sampleRate).map { _ in Float(0.1) })
        legacyWriter.close()
        let legacyJSON = """
        [{"id":"\(UUID().uuidString)","m4aPath":"legacy.m4a",
          "startDate":700000000,"duration":5,"speechDuration":5,"attempts":0,"state":"pending"}]
        """
        try Data(legacyJSON.utf8).write(to: legacyStore)
        let second = TranscriptionQueue(
            storeURL: legacyStore, service: FakeTranscriptionService(text: "hi"), rootDirectory: dir)
        #expect(await second.jobs.first?.source == .phoneMic)

        // And the freshly-persisted omi job survives a reload with source intact.
        let reloaded = TranscriptionQueue(
            storeURL: store, service: FakeTranscriptionService(text: "hi"), rootDirectory: dir)
        #expect(await reloaded.jobs.first?.source == .omi)
    }

    @Test func recordQueuedSegmentStoresOmiSourceAndDefaultsNilForPhoneMic() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SourceLabelTests-\(UUID().uuidString)")
        let store = DayIndexStore(rootDirectory: root)
        let dayDir = root.appendingPathComponent("2026-03-14", isDirectory: true)
        try FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)

        let omiURL = dayDir.appendingPathComponent("09-15-30.m4a")
        await store.recordQueuedSegment(
            m4aURL: omiURL, startTime: Date(timeIntervalSince1970: 0), duration: 10, source: .omi)
        let micURL = dayDir.appendingPathComponent("10-00-00.m4a")
        await store.recordQueuedSegment(
            m4aURL: micURL, startTime: Date(timeIntervalSince1970: 1000), duration: 10)

        let index = await store.index(forDay: dayDir)
        #expect(index?.segments.first { $0.id == "09-15-30" }?.source == "omi")
        #expect(index?.segments.first { $0.id == "10-00-00" }?.source == nil)
    }

    @Test func dayIndexRebuilderReadsSourceFromFrontmatter() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SourceLabelTests-\(UUID().uuidString)")
            .appendingPathComponent("2026-03-14", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let md = """
        ---
        date: 2026-03-14T09:15:30-04:00
        duration: 10
        backend: speechAnalyzer
        source: omi
        ---

        Hello from the Omi.
        """
        try md.write(to: dir.appendingPathComponent("09-15-30.md"), atomically: true, encoding: .utf8)
        let index = DayIndexRebuilder.rebuild(dayDirectory: dir)
        #expect(index.segments.first?.source == "omi")
    }
}

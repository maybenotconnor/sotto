import Foundation
import Testing
@testable import Sotto

/// Test double: records the calls it receives so a test can assert the fan-out drove the
/// expected upsert/remove. An actor because the fan-out invokes it from detached tasks.
actor RecordingSink: TranscriptSyncSink {
    enum Call: Equatable, Sendable {
        case upsert(day: String, basename: String)
        case remove(day: String, basename: String)
    }
    private(set) var calls: [Call] = []

    func upsert(_ segment: SyncSegment) async {
        calls.append(.upsert(day: segment.day, basename: segment.basename))
    }
    func remove(day: String, basename: String) async {
        calls.append(.remove(day: day, basename: basename))
    }

    /// Polls until at least `n` calls have landed (fan-out is detached/async) or ~2 s elapses.
    func waitForCalls(_ n: Int) async -> [Call] {
        for _ in 0..<200 {
            if calls.count >= n { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return calls
    }
}

@Suite(.serialized)
struct SyncFanOutTests {
    private func freshSuite() -> UserDefaults {
        UserDefaults(suiteName: "fan-out-\(UUID().uuidString)")!
    }

    @Test func upsertFansOutDerivedSegmentToEverySink() async {
        let recorder = RecordingSink()
        SyncSinkRegistry.testSinks = [recorder]
        defer { SyncSinkRegistry.testSinks = nil }

        let m4a = URL(fileURLWithPath: "/tmp/Sotto/2026-07-05/09-15-00.m4a")
        SyncSinkRegistry.upsert(m4aURL: m4a, SettingsStore(defaults: freshSuite()))

        let calls = await recorder.waitForCalls(1)
        #expect(calls == [.upsert(day: "2026-07-05", basename: "09-15-00")])
    }

    @Test func removeFansOutDerivedCoordinatesToEverySink() async {
        let recorder = RecordingSink()
        SyncSinkRegistry.testSinks = [recorder]
        defer { SyncSinkRegistry.testSinks = nil }

        let m4a = URL(fileURLWithPath: "/tmp/Sotto/2026-07-05/09-15-00.m4a")
        SyncSinkRegistry.remove(m4aURL: m4a, SettingsStore(defaults: freshSuite()))

        let calls = await recorder.waitForCalls(1)
        #expect(calls == [.remove(day: "2026-07-05", basename: "09-15-00")])
    }

    /// `for sink in activeSinks` must actually iterate — a single-sink test can't tell a loop
    /// from a first-element-only bug. Two independent recorders, one upsert, both must see it.
    @Test func upsertFansOutToEveryRegisteredSinkWhenMoreThanOnePresent() async {
        let recorderA = RecordingSink()
        let recorderB = RecordingSink()
        SyncSinkRegistry.testSinks = [recorderA, recorderB]
        defer { SyncSinkRegistry.testSinks = nil }

        let m4a = URL(fileURLWithPath: "/tmp/Sotto/2026-07-05/09-15-00.m4a")
        SyncSinkRegistry.upsert(m4aURL: m4a, SettingsStore(defaults: freshSuite()))

        let callsA = await recorderA.waitForCalls(1)
        let callsB = await recorderB.waitForCalls(1)
        #expect(callsA == [.upsert(day: "2026-07-05", basename: "09-15-00")])
        #expect(callsB == [.upsert(day: "2026-07-05", basename: "09-15-00")])
    }

    @Test func iCloudSinkPresentWhenEnabled() {
        let settings = SettingsStore(defaults: freshSuite())   // default on
        let sinks = SyncSinkRegistry.activeSinks(settings)
        #expect(sinks.count == 1)
        #expect(sinks.first is ICloudSyncSink)
    }

    @Test func noSinksWhenDisabled() {
        let settings = SettingsStore(defaults: freshSuite())
        settings.iCloudBackupEnabled = false
        #expect(SyncSinkRegistry.activeSinks(settings).isEmpty)
    }

    // --- AppModel site wiring: each mutation drives the expected verb through the registry ---

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fan-out-appmodel-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @MainActor @Test func deleteSegmentFansOutRemove() async {
        let recorder = RecordingSink()
        SyncSinkRegistry.testSinks = [recorder]
        defer { SyncSinkRegistry.testSinks = nil }

        let root = tempDir()
        let dayDir = root.appendingPathComponent("2026-07-05", isDirectory: true)
        try! FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)
        let m4a = dayDir.appendingPathComponent("09-15-00.m4a")
        try! Data([0x01]).write(to: m4a)
        try! "body".write(to: dayDir.appendingPathComponent("09-15-00.md"), atomically: true, encoding: .utf8)

        let model = AppModel(segmentRootOverride: root)
        await model.deleteSegment(m4aURL: m4a)

        let calls = await recorder.waitForCalls(1)
        #expect(calls == [.remove(day: "2026-07-05", basename: "09-15-00")])
    }

    /// Merge-site wiring: unlike delete/rename, `mergeSegments` guards on `dayIndex` being
    /// populated (`guard let dayIndex else { return false }`), so this test drives a real
    /// `ensureSetUp()` + `loadInitialHistory()` first — reusing the exact fixture/setup
    /// pattern `AppModelTests.mergeSegmentsCombinesFilesIndexAndHistory` already established
    /// (yesterday's day folder, `ConversationMergerTests.partOne`/`partTwo` as the two parts).
    /// Merge fans out an upsert for the earliest/merged part plus a remove for every
    /// merged-away part (design §3) — here one of each.
    @MainActor @Test func mergeSegmentsFansOutUpsertForMergedAndRemoveForEachPart() async {
        let recorder = RecordingSink()
        SyncSinkRegistry.testSinks = [recorder]
        defer { SyncSinkRegistry.testSinks = nil }

        let root = tempDir()
        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.calendar = Calendar(identifier: .gregorian)
        dayFormatter.dateFormat = "yyyy-MM-dd"
        // Yesterday, so refreshLoadedHistory's "prepend today" logic stays out of the way
        // (same rationale as AppModelTests.mergeSegmentsCombinesFilesIndexAndHistory).
        let day = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        let dayName = dayFormatter.string(from: day)
        let dir = root.appendingPathComponent(dayName, isDirectory: true)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try! ConversationMergerTests.partOne.write(
            to: dir.appendingPathComponent("09-15-30.md"), atomically: true, encoding: .utf8)
        try! ConversationMergerTests.partTwo.write(
            to: dir.appendingPathComponent("10-01-00.md"), atomically: true, encoding: .utf8)

        let model = AppModel(
            assetInstaller: FakeAssetInstaller(installed: true), segmentRootOverride: root)
        await model.ensureSetUp()
        await model.loadInitialHistory()   // no _day.json → rebuilds; both entries "done"
        let section = model.historySections[0]
        #expect(section.index.segments.count == 2)

        let ok = await model.mergeSegments(
            dayDirectory: section.dayDirectory, entries: section.index.segments)
        #expect(ok)

        // regenerateNotes is spawned detached but early-returns unless
        // FoundationModelsPostProcessor.isModelAvailable, which is false in the simulator — so
        // no extra upsert fires and exactly these two calls land.
        let calls = await recorder.waitForCalls(2)
        #expect(calls.count == 2)
        #expect(calls.contains(.upsert(day: dayName, basename: "09-15-30")))   // earliest/merged
        #expect(calls.contains(.remove(day: dayName, basename: "10-01-00")))   // merged-away part
    }

    @MainActor @Test func renameSegmentFansOutUpsert() async {
        let recorder = RecordingSink()
        SyncSinkRegistry.testSinks = [recorder]
        defer { SyncSinkRegistry.testSinks = nil }

        let root = tempDir()
        let dayDir = root.appendingPathComponent("2026-07-05", isDirectory: true)
        try! FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)
        let m4a = dayDir.appendingPathComponent("09-15-00.m4a")
        try! Data([0x01]).write(to: m4a)
        // A valid transcript so ConversationMerger.applyTitle succeeds (else rename returns early).
        try! """
        ---
        date: 2026-07-05T09:15:00Z
        duration: 5.0
        ---

        **Speaker 0:** hi
        """.write(to: dayDir.appendingPathComponent("09-15-00.md"), atomically: true, encoding: .utf8)

        let model = AppModel(segmentRootOverride: root)
        await model.renameSegment(m4aURL: m4a, title: "New title",
                                  startTime: Date(timeIntervalSince1970: 1_783_667_700))

        let calls = await recorder.waitForCalls(1)
        #expect(calls == [.upsert(day: "2026-07-05", basename: "09-15-00")])
    }
}

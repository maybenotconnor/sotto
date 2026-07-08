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
}

import Foundation
import Synchronization
import Testing
@testable import Sotto

struct RecorderStateMachineTests {
    private func chunk() -> AudioChunk {
        AudioChunk(samples: [Float](repeating: 0, count: VADConstants.chunkSize), hostTime: 0)
    }

    private func makeMachine(
        script: [Int: SpeechEvent],
        config: RecorderConfig = RecorderConfig(),
        factory: FakeWriterFactory = FakeWriterFactory()
    ) -> (RecorderStateMachine, FakeWriterFactory) {
        let store = SegmentStore(rootDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent("RecorderTests-\(UUID().uuidString)"))
        let machine = RecorderStateMachine(
            detector: FakeSpeechDetector(script: script),
            writerFactory: factory, store: store, config: config)
        return (machine, factory)
    }

    @Test func speechStartOpensSegmentAndFlushesPreRoll() async throws {
        let (machine, factory) = makeMachine(script: [2: .speechStart(time: nil)])
        _ = await machine.beginListening()
        for _ in 0..<3 { _ = await machine.process(chunk()) }   // chunks 0,1 listening; 2 → start

        #expect(factory.writers.count == 1)
        // Pre-roll flush: chunks 0–2 were all appended to pre-roll before the event fired,
        // so the writer's FIRST append is the pre-roll snapshot (3 × 4096 = 12,288 samples,
        // under the 16,000 capacity).
        #expect(factory.writers[0].appendCalls.first == 3 * VADConstants.chunkSize)
        let snap = await machine.process(chunk())
        #expect(snap.state == .recording)
        #expect(factory.writers[0].appendCalls.count == 2)      // pre-roll + live chunk
    }

    @Test func speechEndEntersSilenceAndKeepsWriting() async throws {
        let (machine, factory) = makeMachine(script: [0: .speechStart(time: nil), 2: .speechEnd(time: nil)])
        _ = await machine.beginListening()
        for _ in 0..<3 { _ = await machine.process(chunk()) }
        let snap = await machine.process(chunk())               // chunk 3: in silence
        #expect(snap.state == .silence)
        // Silence chunks are still written (seamless if speech resumes). Append count is 4:
        // chunk 0 lives INSIDE the pre-roll flush (one append), then live chunks 1, 2, 3 —
        // chunk 2 carried the speechEnd but is still appended; chunk 3 is appended in silence.
        #expect(factory.writers[0].appendCalls.count == 4)
    }

    @Test func silenceTimeoutFinalizesAndReturnsToListening() async throws {
        var config = RecorderConfig()
        config.silenceTimeout = 1.0                              // 1 s ≈ 4 chunks of 256 ms
        config.minSegmentSpeechDuration = 0                      // don't trip the min guard here
        let (machine, factory) = makeMachine(
            script: [0: .speechStart(time: nil), 1: .speechEnd(time: nil)], config: config)
        _ = await machine.beginListening()
        var last = RecorderSnapshot(state: .idle, finalizedCount: 0, lastEvent: nil)
        for _ in 0..<8 { last = await machine.process(chunk()) }

        #expect(factory.writers[0].finalized)
        #expect(last.state == .listening)
        #expect(last.finalizedCount == 1)
    }

    @Test func speechResumeDuringSilenceReturnsToRecording() async throws {
        var config = RecorderConfig()
        config.silenceTimeout = 10
        let (machine, factory) = makeMachine(
            script: [0: .speechStart(time: nil), 1: .speechEnd(time: nil), 3: .speechStart(time: nil)],
            config: config)
        _ = await machine.beginListening()
        var last = RecorderSnapshot(state: .idle, finalizedCount: 0, lastEvent: nil)
        for _ in 0..<5 { last = await machine.process(chunk()) }
        #expect(last.state == .recording)
        #expect(!factory.writers[0].finalized)
        #expect(factory.writers.count == 1)                     // same segment, no split
    }

    @Test func shortSegmentIsDiscardedNotFinalized() async throws {
        var config = RecorderConfig()
        config.silenceTimeout = 0.5                              // 2 chunks
        config.minSegmentSpeechDuration = 3                      // speech here is ~0.25 s → discard
        let (machine, factory) = makeMachine(
            script: [0: .speechStart(time: nil), 1: .speechEnd(time: nil)], config: config)
        _ = await machine.beginListening()
        var last = RecorderSnapshot(state: .idle, finalizedCount: 0, lastEvent: nil)
        for _ in 0..<6 { last = await machine.process(chunk()) }

        #expect(factory.writers[0].discarded)
        #expect(!factory.writers[0].finalized)
        #expect(last.finalizedCount == 0)
        #expect(last.state == .listening)
    }

    @Test func maxSegmentDurationRotatesIntoNewSegmentWhileRecording() async throws {
        var config = RecorderConfig()
        config.maxSegmentDuration = 2.0                          // ≈ 8 chunks incl. pre-roll
        config.minSegmentSpeechDuration = 0
        let (machine, factory) = makeMachine(script: [0: .speechStart(time: nil)], config: config)
        _ = await machine.beginListening()
        var last = RecorderSnapshot(state: .idle, finalizedCount: 0, lastEvent: nil)
        for _ in 0..<12 { last = await machine.process(chunk()) }

        #expect(factory.writers.count == 2)                      // rotated exactly once so far
        #expect(factory.writers[0].finalized)
        #expect(!factory.writers[1].finalized)
        #expect(last.state == .recording)                        // still recording, new file
        #expect(last.finalizedCount == 1)
    }

    @Test func finishAndFinalizeClosesOpenSegment() async throws {
        var config = RecorderConfig()
        config.minSegmentSpeechDuration = 0
        let (machine, factory) = makeMachine(script: [0: .speechStart(time: nil)], config: config)
        _ = await machine.beginListening()
        for _ in 0..<3 { _ = await machine.process(chunk()) }
        let snap = await machine.finishAndFinalize()

        #expect(factory.writers[0].finalized)
        #expect(snap.state == .idle)
        #expect(snap.finalizedCount == 1)
    }

    @Test func diskGuardBlocksNewSegments() async throws {
        var config = RecorderConfig()
        config.minFreeDiskBytes = .max                           // impossible requirement
        let (machine, factory) = makeMachine(script: [0: .speechStart(time: nil)], config: config)
        _ = await machine.beginListening()
        let snap = await machine.process(chunk())

        #expect(factory.writers.isEmpty)
        #expect(snap.state == .listening)                        // stayed listening
        #expect(snap.lastEvent?.contains("disk") == true)
    }

    @Test func segmentHandlerReceivesFinalizedSegment() async throws {
        var config = RecorderConfig()
        config.silenceTimeout = 0.5
        config.minSegmentSpeechDuration = 0
        let (machine, _) = makeMachine(
            script: [0: .speechStart(time: nil), 1: .speechEnd(time: nil)], config: config)
        let received = Mutex<[FinalizedSegment]>([])
        await machine.setSegmentHandler { segment in
            received.withLock { $0.append(segment) }
        }
        _ = await machine.beginListening()
        for _ in 0..<6 { _ = await machine.process(chunk()) }

        let segments = received.withLock { $0 }
        #expect(segments.count == 1)
        #expect(segments[0].duration > 0)
        #expect(segments[0].cafURL.lastPathComponent.hasSuffix(".caf"))
    }

    @Test func vadErrorsDuringSilenceStillReachTimeout() async throws {
        var config = RecorderConfig()
        config.silenceTimeout = 0.5                       // 2 chunks of 256 ms
        config.minSegmentSpeechDuration = 0
        let factory = FakeWriterFactory()
        let store = SegmentStore(rootDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent("RecorderTests-\(UUID().uuidString)"))
        let machine = RecorderStateMachine(
            detector: ThrowingSpeechDetector(
                script: [0: .speechStart(time: nil), 1: .speechEnd(time: nil)], throwFrom: 2),
            writerFactory: factory, store: store, config: config)

        _ = await machine.beginListening()
        var last = RecorderSnapshot(state: .idle, finalizedCount: 0, lastEvent: nil)
        for _ in 0..<6 { last = await machine.process(chunk()) }   // chunks 2+ all throw

        #expect(factory.writers[0].finalized)             // timeout still fired through errors
        #expect(last.finalizedCount == 1)
        #expect(last.state == .listening)
    }

    @Test func currentSegmentStartDateTracksSegmentLifecycle() async throws {
        var config = RecorderConfig()
        config.silenceTimeout = 0.5
        config.minSegmentSpeechDuration = 0
        let (machine, _) = makeMachine(
            script: [0: .speechStart(time: nil), 1: .speechEnd(time: nil)], config: config)
        var snap = await machine.beginListening()
        #expect(snap.currentSegmentStartDate == nil)
        snap = await machine.process(chunk())          // speechStart → segment opens
        #expect(snap.currentSegmentStartDate != nil)
        for _ in 0..<5 { snap = await machine.process(chunk()) }   // silence timeout → finalize
        #expect(snap.currentSegmentStartDate == nil)
    }

    @Test func failedSegmentOpenClearsSegmentStartDate() async throws {
        final class ExplodingWriter: SegmentWriting {
            struct Boom: Error {}
            let cafURL = URL(fileURLWithPath: "/tmp/x.caf")
            let m4aURL = URL(fileURLWithPath: "/tmp/x.m4a")
            private(set) var writtenSampleCount = 0
            func append(_ samples: [Float]) throws { throw Boom() }
            func close() {}
            func discard() {}
        }
        final class ExplodingFactory: SegmentWriterFactory, @unchecked Sendable {
            func makeWriter(startDate: Date) throws -> any SegmentWriting { ExplodingWriter() }
        }
        let store = SegmentStore(rootDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent("ExplodeTests-\(UUID().uuidString)"))
        let machine = RecorderStateMachine(
            detector: FakeSpeechDetector(script: [0: .speechStart(time: nil)]),
            writerFactory: ExplodingFactory(), store: store, config: RecorderConfig())
        _ = await machine.beginListening()
        let snap = await machine.process(chunk())   // speechStart → open fails on flush append
        #expect(snap.currentSegmentStartDate == nil)   // no phantom live row
        #expect(snap.state == .listening)              // stayed listening (existing behavior)
    }

    @Test func markInterruptedFinalizesAndParksState() async throws {
        var config = RecorderConfig()
        config.minSegmentSpeechDuration = 0
        let (machine, factory) = makeMachine(script: [0: .speechStart(time: nil)], config: config)
        _ = await machine.beginListening()
        for _ in 0..<3 { _ = await machine.process(chunk()) }
        let snap = await machine.markInterrupted()

        #expect(factory.writers[0].finalized)
        #expect(snap.state == .interrupted)
        // Chunks arriving while interrupted are ignored:
        let after = await machine.process(chunk())
        #expect(after.state == .interrupted)
        #expect(factory.writers.count == 1)
    }

    // MARK: - M12 Task 6: active-source stamping + rollover

    @Test func rolloverFinalizesOpenSegmentWithOldSourceAndKeepsListening() async throws {
        // Two speechStarts: index 0 opens the first (pre-rollover) segment, index 20
        // opens the second (post-rollover) segment. No speechEnd is ever scripted, so
        // both segments stay in `.recording` the whole time — this exercises rollover's
        // reuse of the min-length guard while mid-speech (not just at a silence edge).
        let (machine, _) = makeMachine(script: [0: .speechStart(time: nil), 20: .speechStart(time: nil)])
        let captured = Mutex<[FinalizedSegment]>([])
        await machine.setSegmentHandler { segment in
            captured.withLock { $0.append(segment) }
        }
        await machine.setActiveSource(.omi)
        _ = await machine.beginListening()
        // 20 chunks × 4096 samples = 81,920 samples ≈ 5.1 s of "speech" — comfortably
        // past the default 3 s minSegmentSpeechDuration guard.
        for _ in 0..<20 { _ = await machine.process(chunk()) }

        let snapshot = await machine.rollover(to: .phoneMic)
        #expect(snapshot.state == .listening)
        #expect(captured.withLock { $0 }.count == 1)
        #expect(captured.withLock { $0 }.last?.source == .omi)

        // Drive another valid segment (now on the new source) and finalize it.
        for _ in 0..<20 { _ = await machine.process(chunk()) }
        _ = await machine.finishAndFinalize()
        #expect(captured.withLock { $0 }.count == 2)
        #expect(captured.withLock { $0 }.last?.source == .phoneMic)
    }

    @Test func rolloverWhileListeningJustSwitchesSource() async throws {
        let (machine, _) = makeMachine(script: [:])
        let captured = Mutex<[FinalizedSegment]>([])
        await machine.setSegmentHandler { segment in
            captured.withLock { $0.append(segment) }
        }
        _ = await machine.beginListening()

        let snapshot = await machine.rollover(to: .omi)

        #expect(snapshot.state == .listening)
        #expect(captured.withLock { $0 }.isEmpty)
    }

    @Test func rolloverWhileIdleOnlySetsSource() async throws {
        let (machine, _) = makeMachine(script: [:])

        let snapshot = await machine.rollover(to: .omi)

        #expect(snapshot.state == .idle)
    }
}

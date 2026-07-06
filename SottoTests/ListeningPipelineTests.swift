import Testing
@testable import Sotto

@MainActor
struct ListeningPipelineTests {
    @Test func recorderStatesDriveStatus() async throws {
        let source = FakeAudioSource()
        let recorder = FakeRecorder(stateScript: [2: .recording, 5: .silence])
        let pipeline = ListeningPipeline(source: source, recorder: recorder)

        await pipeline.start()
        #expect(pipeline.status == .listening)
        await source.emitSilentChunks(count: 6)
        await source.finish()
        await pipeline.waitUntilDrained()

        #expect(pipeline.status == .silence)   // last scripted state (index 5)
        await pipeline.stop()
        #expect(pipeline.status == .idle)
    }

    @Test func stopDrainsPumpBeforeFinalize() async throws {
        let source = FakeAudioSource()
        let recorder = FakeRecorder()
        let pipeline = ListeningPipeline(source: source, recorder: recorder)

        await pipeline.start()
        await source.emitSilentChunks(count: 3)
        // Deliberately no waitUntilDrained(): stop() itself must drain, THEN finalize.
        await pipeline.stop()

        #expect(await recorder.processedChunks == 3)
        #expect(await recorder.processedAfterFinish == 0)   // drain-before-finalize invariant
        #expect(await recorder.finishCount == 1)
        #expect(pipeline.status == .idle)
    }

    @Test func startIsIdempotentWhileActive() async throws {
        let source = FakeAudioSource()
        let pipeline = ListeningPipeline(source: source, recorder: FakeRecorder())

        await pipeline.start()
        await pipeline.start()   // second start while listening must be a no-op
        #expect(pipeline.status == .listening)
        #expect(await source.startCallCount == 1)
        await pipeline.stop()
    }

    @Test func concurrentStartsOnlyStartSourceOnce() async throws {
        let source = FakeAudioSource()
        let pipeline = ListeningPipeline(source: source, recorder: FakeRecorder())

        async let first: Void = pipeline.start()
        async let second: Void = pipeline.start()
        _ = await (first, second)

        #expect(await source.startCallCount == 1)
        #expect(pipeline.status == .listening)
        await pipeline.stop()
    }

    @Test func statusIsStartingWhileSourceStartIsInFlight() async throws {
        let source = SlowStartAudioSource()
        let pipeline = ListeningPipeline(source: source, recorder: FakeRecorder())

        async let starting: Void = pipeline.start()
        await source.waitUntilStartRequested()
        #expect(pipeline.status == .starting)
        await source.releaseStart()
        await starting
        #expect(pipeline.status == .listening)
        await pipeline.stop()
    }

    @Test func queuedStopReturnsOnlyOncePipelineIsIdle() async throws {
        let source = SlowStartAudioSource()
        let recorder = FakeRecorder()
        let pipeline = ListeningPipeline(source: source, recorder: recorder)

        async let starting: Void = pipeline.start()
        await source.waitUntilStartRequested()
        async let stopping: Void = pipeline.stop()
        for _ in 0..<5 { await Task.yield() }
        await source.releaseStart()
        await stopping
        #expect(pipeline.status == .idle)
        #expect(await recorder.finishCount == 1)
        await starting
    }

    @Test func startStopStartBurstEndsIdleWithoutOrphanedPump() async throws {
        let source = SlowStartAudioSource()
        let recorder = FakeRecorder()
        let pipeline = ListeningPipeline(source: source, recorder: recorder)

        async let firstStart: Void = pipeline.start()
        await source.waitUntilStartRequested()
        async let stopping: Void = pipeline.stop()
        async let secondStart: Void = pipeline.start()
        for _ in 0..<5 { await Task.yield() }
        await source.releaseStart()
        _ = await (firstStart, stopping, secondStart)

        #expect(pipeline.status == .idle)
        await source.emitSilentChunks(count: 2)
        for _ in 0..<10 { await Task.yield() }
        #expect(await recorder.processedAfterFinish == 0)   // no orphaned pump feeding chunks
    }

    @Test func droppingPipelineWithoutStopTearsDownSource() async throws {
        let source = FakeAudioSource()
        var pipeline: ListeningPipeline? = ListeningPipeline(source: source, recorder: FakeRecorder())
        await pipeline?.start()
        await source.emitSilentChunks(count: 2)

        pipeline = nil   // owner forgot stop(); deinit must still tear down the source

        var stopped = false
        for _ in 0..<50 where !stopped {
            try await Task.sleep(for: .milliseconds(10))
            stopped = await source.stopCallCount > 0
        }
        #expect(stopped)
    }

    @Test func liveActivityFollowsSessionLifecycle() async throws {
        let source = FakeAudioSource()
        let activity = FakeLiveActivityController()
        let pipeline = ListeningPipeline(
            source: source, recorder: FakeRecorder(stateScript: [1: .recording]),
            liveActivity: activity)

        await pipeline.start()
        #expect(activity.startedCount == 1)
        await source.emitSilentChunks(count: 2)
        await source.finish()
        await pipeline.waitUntilDrained()
        #expect(activity.updates.contains { $0.phase == .recording })
        await pipeline.stop()
        #expect(activity.endedCount == 1)
    }
}

import Testing
@testable import Sotto

@MainActor
struct ListeningPipelineTests {
    @Test func speechEventsDriveStatusAndLog() async throws {
        let source = FakeAudioSource()
        let detector = FakeSpeechDetector(script: [
            2: .speechStart(time: 0.5),
            5: .speechEnd(time: 1.5),
        ])
        let pipeline = ListeningPipeline(source: source, detector: detector)

        await pipeline.start()
        #expect(pipeline.status == .listening)

        await source.emitSilentChunks(count: 6)
        await source.finish()
        await pipeline.waitUntilDrained()

        #expect(pipeline.eventLog.contains("Speech started"))
        #expect(pipeline.eventLog.contains("Speech ended"))
        #expect(pipeline.status == .listening)   // ended → back to listening
    }

    @Test func preRollAccumulatesAndStopClearsIt() async throws {
        let source = FakeAudioSource()
        let detector = FakeSpeechDetector(script: [:])
        let pipeline = ListeningPipeline(source: source, detector: detector, preRollSamples: 8192)

        await pipeline.start()
        await source.emitSilentChunks(count: 3)   // 12,288 samples into an 8,192 window
        await source.finish()
        await pipeline.waitUntilDrained()
        #expect(pipeline.preRollSnapshot().count == 8192)

        await pipeline.stop()
        #expect(pipeline.preRollSnapshot().isEmpty)
        #expect(pipeline.status == .idle)
    }

    @Test func startIsIdempotentWhileActive() async throws {
        let source = FakeAudioSource()
        let detector = FakeSpeechDetector(script: [:])
        let pipeline = ListeningPipeline(source: source, detector: detector)

        await pipeline.start()
        await pipeline.start()   // second start while listening must be a no-op
        #expect(pipeline.status == .listening)
        await pipeline.stop()
    }

    @Test func concurrentStartsOnlyStartSourceOnce() async throws {
        let source = FakeAudioSource()
        let detector = FakeSpeechDetector(script: [:])
        let pipeline = ListeningPipeline(source: source, detector: detector)

        async let first: Void = pipeline.start()
        async let second: Void = pipeline.start()
        _ = await (first, second)

        #expect(await source.startCallCount == 1)
        #expect(pipeline.status == .listening)
        await pipeline.stop()
    }

    @Test func stopClearsPreRollEvenWithUndrainedChunks() async throws {
        let source = FakeAudioSource()
        let detector = FakeSpeechDetector(script: [:])
        let pipeline = ListeningPipeline(source: source, detector: detector, preRollSamples: 8192)

        await pipeline.start()
        await source.emitSilentChunks(count: 3)
        // Deliberately no waitUntilDrained(): stop() itself must drain then clear.
        await pipeline.stop()

        // Give any orphaned pump task scheduler time — a leaked pump would repopulate preRoll here.
        for _ in 0..<10 { await Task.yield() }

        #expect(pipeline.preRollSnapshot().isEmpty)
        #expect(pipeline.status == .idle)
    }

    @Test func stopDuringStartLeavesPipelineIdleWithNoPump() async throws {
        let source = SlowStartAudioSource()
        let detector = FakeSpeechDetector(script: [:])
        let pipeline = ListeningPipeline(source: source, detector: detector)

        async let starting: Void = pipeline.start()
        await source.waitUntilStartRequested()
        async let stopping: Void = pipeline.stop()   // queued; suspends until the deferred stop completes
        for _ in 0..<5 { await Task.yield() }        // let stop() reach the queue while the gate is closed
        await source.releaseStart()
        _ = await (starting, stopping)

        #expect(pipeline.status == .idle)
        await source.emitSilentChunks(count: 2)
        for _ in 0..<10 { await Task.yield() }
        #expect(pipeline.preRollSnapshot().isEmpty)   // no live pump is consuming chunks
    }

    @Test func startStopStartBurstEndsIdleWithoutOrphanedPump() async throws {
        let source = SlowStartAudioSource()
        let detector = FakeSpeechDetector(script: [:])
        let pipeline = ListeningPipeline(source: source, detector: detector)

        async let firstStart: Void = pipeline.start()
        await source.waitUntilStartRequested()
        async let stopping: Void = pipeline.stop()         // queued: start is mid-flight
        async let secondStart: Void = pipeline.start()     // must no-op: a transition is in flight
        for _ in 0..<5 { await Task.yield() }              // let both hit their guards while the gate is closed
        await source.releaseStart()
        _ = await (firstStart, stopping, secondStart)

        #expect(pipeline.status == .idle)                  // the queued stop won after the start completed
        await source.emitSilentChunks(count: 2)
        for _ in 0..<10 { await Task.yield() }
        #expect(pipeline.preRollSnapshot().isEmpty)        // no orphaned pump is consuming chunks
    }

    @Test func statusIsStartingWhileSourceStartIsInFlight() async throws {
        let source = SlowStartAudioSource()
        let detector = FakeSpeechDetector(script: [:])
        let pipeline = ListeningPipeline(source: source, detector: detector)

        async let starting: Void = pipeline.start()
        await source.waitUntilStartRequested()
        #expect(pipeline.status == .starting)   // NOT .listening: no audio is flowing yet
        await source.releaseStart()
        await starting
        #expect(pipeline.status == .listening)
        await pipeline.stop()
    }

    @Test func queuedStopReturnsOnlyOncePipelineIsIdle() async throws {
        let source = SlowStartAudioSource()
        let detector = FakeSpeechDetector(script: [:])
        let pipeline = ListeningPipeline(source: source, detector: detector)

        async let starting: Void = pipeline.start()
        await source.waitUntilStartRequested()
        async let stopping: Void = pipeline.stop()
        for _ in 0..<5 { await Task.yield() }
        await source.releaseStart()
        await stopping                        // must resume only after the deferred stop drained
        #expect(pipeline.status == .idle)     // stop()'s return now implies idle
        await starting
    }

    @Test func droppingPipelineWithoutStopTearsDownSource() async throws {
        let source = FakeAudioSource()
        let detector = FakeSpeechDetector(script: [:])
        var pipeline: ListeningPipeline? = ListeningPipeline(source: source, detector: detector)
        await pipeline?.start()
        await source.emitSilentChunks(count: 2)

        pipeline = nil   // owner forgot stop(); deinit must still tear down the source

        var stopped = false
        for _ in 0..<50 where !stopped {
            try await Task.sleep(for: .milliseconds(10))
            stopped = await source.stopCallCount > 0
        }
        #expect(stopped)   // without deinit teardown the audio stack would run forever
    }
}

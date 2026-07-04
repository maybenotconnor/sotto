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
        await pipeline.stop()            // wins the race while start() is suspended
        await source.releaseStart()
        await starting

        #expect(pipeline.status == .idle)
        await source.emitSilentChunks(count: 2)
        for _ in 0..<10 { await Task.yield() }
        #expect(pipeline.preRollSnapshot().isEmpty)   // no live pump is consuming chunks
    }
}

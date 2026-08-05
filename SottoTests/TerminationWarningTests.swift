import Foundation
import Testing
@testable import Sotto

/// Force-quit warning (2026-08-04 field incident): iOS delivers willTerminate to a
/// *running* app being swiped away, but the process exits the moment the synchronous
/// callbacks return — device-log measured at ~8 ms (2026-08-05), so the warning must be
/// decided and fired inline on that thread. The pipeline owns the DECISION only, as the
/// synchronous `shouldWarnOnTermination` gate tested here; AppModel's observer fires the
/// notification and blocks until the daemon acks (untestable glue, like the scheduler).
@MainActor
struct TerminationWarningTests {
    @Test func warnsWhenTerminatedWhileCapturing() async throws {
        let mic = FakeSimpleAudioSource()
        let pipeline = ListeningPipeline(source: mic, recorder: FakeRecorder())
        await pipeline.start()
        #expect(pipeline.activeSourceType == .phoneMic)

        #expect(pipeline.shouldWarnOnTermination)
        await pipeline.stop()
    }

    @Test func noWarningWhenIdle() async throws {
        let pipeline = ListeningPipeline(source: FakeSimpleAudioSource(),
                                         recorder: FakeRecorder())
        #expect(!pipeline.shouldWarnOnTermination)
    }

    @Test func noWarningWhileWaitingForCapture() async throws {
        // Waiting already alerted via the 30 s capture-unavailable notification — a
        // force-quit there must not stack a second, contradictory "was recording" alert.
        struct Boom: Error {}
        let omi = FakeConnectableAudioSource()
        let mic = FakeSimpleAudioSource()
        await mic.setStartError(Boom())
        let failover = FailoverAudioSource(
            wearable: omi, phoneMic: mic,
            config: FailoverConfig(reconnectGrace: .milliseconds(60),
                                   returnHysteresis: .milliseconds(80)))
        let pipeline = ListeningPipeline(source: failover, recorder: FakeRecorder())
        await pipeline.start()
        try await Task.sleep(for: .milliseconds(100))
        #expect(pipeline.isWaitingForCapture)

        #expect(!pipeline.shouldWarnOnTermination)
        await pipeline.stop()
    }

    @Test func noWarningWhenInterrupted() async throws {
        // A parked session already delivered the "Sotto was paused" notification; the user
        // has been told recording is not running.
        let mic = FakeSimpleAudioSource()
        let pipeline = ListeningPipeline(source: mic, recorder: FakeRecorder())
        await pipeline.start()
        await pipeline.interrupt()
        #expect(pipeline.status == .interrupted)

        #expect(!pipeline.shouldWarnOnTermination)
        await pipeline.stop()
    }
}

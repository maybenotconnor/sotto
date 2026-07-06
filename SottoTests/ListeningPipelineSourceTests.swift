import Foundation
import Testing
@testable import Sotto

/// M12 Task 8: `ListeningPipeline` wired to a `SourceSwitchingAudioSource` — rollover,
/// notifications, and `activeSourceType` publishing. Uses a real `FailoverAudioSource` (with a
/// fast config) as the integration seam between the two.
@MainActor
struct ListeningPipelineSourceTests {
    private let fastConfig = FailoverConfig(
        startupRace: .milliseconds(60),
        reconnectGrace: .milliseconds(60),
        returnHysteresis: .milliseconds(80))

    @Test func fallbackRollsRecorderOverAndNotifies() async throws {
        let omi = FakeConnectableAudioSource()
        let mic = FakeSimpleAudioSource()
        let failover = FailoverAudioSource(omi: omi, phoneMic: mic, config: fastConfig)
        let recorder = FakeRecorder()
        let notifications = FakeNotificationScheduler()
        let pipeline = ListeningPipeline(source: failover, recorder: recorder,
                                         notifications: notifications)
        await pipeline.start()
        await omi.setState(.streaming)
        try await Task.sleep(for: .milliseconds(60))
        #expect(pipeline.activeSourceType == .omi)

        await omi.setState(.disconnected)
        try await Task.sleep(for: .milliseconds(300))
        #expect(pipeline.activeSourceType == .phoneMic)
        #expect(await recorder.rolloverCalls.last == .phoneMic)
        #expect(await notifications.sourceFallbackCount == 1)

        await omi.setState(.streaming)
        try await Task.sleep(for: .milliseconds(350))
        #expect(pipeline.activeSourceType == .omi)
        #expect(await recorder.rolloverCalls.last == .omi)
        // Recovery is silent (no fallback re-fired) and the earlier fallback notification
        // is still exactly one — omiRecovered schedules nothing.
        #expect(await notifications.sourceFallbackCount == 1)
        await pipeline.stop()
        #expect(pipeline.activeSourceType == nil)
    }

    @Test func captureUnavailableNotifiesLoudly() async throws {
        struct Boom: Error {}
        let omi = FakeConnectableAudioSource()
        let mic = FakeSimpleAudioSource()
        await mic.setStartError(Boom())
        let failover = FailoverAudioSource(omi: omi, phoneMic: mic, config: fastConfig)
        let notifications = FakeNotificationScheduler()
        let pipeline = ListeningPipeline(source: failover, recorder: FakeRecorder(),
                                         notifications: notifications)
        await pipeline.start()
        await omi.setState(.streaming)
        try await Task.sleep(for: .milliseconds(60))
        await omi.setState(.disconnected)
        try await Task.sleep(for: .milliseconds(300))
        #expect(await notifications.captureUnavailableCount == 1)
        #expect(pipeline.activeSourceType == nil)
        await pipeline.stop()
    }

    @Test func plainSourceHasNilActiveSourceUntilStartThenPhoneMic() async throws {
        // A non-switching source (plain fake) sets activeSourceType from sourceType.
        let mic = FakeSimpleAudioSource()
        let pipeline = ListeningPipeline(source: mic, recorder: FakeRecorder())
        #expect(pipeline.activeSourceType == nil)
        await pipeline.start()
        #expect(pipeline.activeSourceType == .phoneMic)
        await pipeline.stop()
        #expect(pipeline.activeSourceType == nil)
    }

    @Test func repeatFallbackEventDoesNotDoubleNotify() async throws {
        // Regression for the RACE B repeat: FailoverAudioSource can emit the SAME source
        // (.phoneMic/.omiDisconnected) twice in a row with no intervening recovery, when the
        // Omi drops again during a suspended phoneMic.stop() mid-return-hysteresis. The
        // pipeline must still roll the recorder over both times (harmless no-op finalize) but
        // must only fire the user-facing notification once.
        let omi = FakeConnectableAudioSource()
        let mic = FakeSimpleAudioSource()
        let failover = FailoverAudioSource(omi: omi, phoneMic: mic, config: fastConfig)
        let recorder = FakeRecorder()
        let notifications = FakeNotificationScheduler()
        let pipeline = ListeningPipeline(source: failover, recorder: recorder,
                                         notifications: notifications)
        await pipeline.start()
        await omi.setState(.streaming)
        try await Task.sleep(for: .milliseconds(60))
        #expect(pipeline.activeSourceType == .omi)

        await omi.setState(.disconnected)
        try await Task.sleep(for: .milliseconds(300))
        #expect(pipeline.activeSourceType == .phoneMic)
        #expect(await notifications.sourceFallbackCount == 1)

        // Arm the return-hysteresis timer, then let the Omi drop again while the mic's stop()
        // (triggered by the hysteresis firing) is suspended — FailoverAudioSourceTests'
        // `omiDropDuringDelayedMicStopRestartsMic` exercises the identical race on the source
        // alone; here we drive it through the pipeline.
        await mic.setStopDelay(150)
        await omi.setState(.streaming)                      // arms the 80 ms return-hysteresis
        try await Task.sleep(for: .milliseconds(90))        // hysteresis fires; phoneMic.stop() suspended
        await omi.setState(.disconnected)                   // omi drops again mid-suspended-stop
        try await Task.sleep(for: .milliseconds(400))        // let everything settle

        #expect(pipeline.activeSourceType == .phoneMic)
        // Still exactly one fallback notification despite the repeat .omiDisconnected event.
        #expect(await notifications.sourceFallbackCount == 1)
        // The recorder DID see the repeat rollover call (harmless no-op finalize-wise).
        #expect(await recorder.rolloverCalls.filter { $0 == .phoneMic }.count >= 2)
        await pipeline.stop()
    }
}

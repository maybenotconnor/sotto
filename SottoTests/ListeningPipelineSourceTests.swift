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

    @Test func coldStartCaptureUnavailableNotifiesLoudly() async throws {
        // Regression: `.captureUnavailable` can be the very FIRST event this pipeline ever
        // sees (Omi loses the startup race AND phoneMic.start() throws immediately, e.g. mic
        // permission denied). `activeSourceType` starts nil, so a dedup keyed on
        // "previousSource != nil" would silently swallow the one notification telling the user
        // nothing is recording.
        struct Boom: Error {}
        let omi = FakeConnectableAudioSource()
        let mic = FakeSimpleAudioSource()
        await mic.setStartError(Boom())
        let failover = FailoverAudioSource(omi: omi, phoneMic: mic, config: fastConfig)
        let notifications = FakeNotificationScheduler()
        let pipeline = ListeningPipeline(source: failover, recorder: FakeRecorder(),
                                         notifications: notifications)
        await pipeline.start()
        // Omi never streams: wait past startupRace (60ms) with margin so the race expires,
        // phoneMic.start() throws, and captureUnavailable fires as the pipeline's first-ever
        // source event.
        try await Task.sleep(for: .milliseconds(200))
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

    /// Recorder whose `rollover(to:)` sleeps briefly before returning — widens the window in
    /// which a `handleSourceChange` call is genuinely in flight (suspended on the recorder
    /// hop) so `stopAfterBufferedSourceChangeEndsIdle` below can land `stop()` inside that
    /// window deterministically, instead of racing real scheduler fairness on an instant fake.
    private actor SlowRolloverRecorder: SegmentRecording {
        private(set) var rolloverCalls: [AudioSourceType] = []
        func beginListening() async -> RecorderSnapshot {
            RecorderSnapshot(state: .listening, finalizedCount: 0, lastEvent: nil)
        }
        func process(_ chunk: AudioChunk) async -> RecorderSnapshot {
            RecorderSnapshot(state: .listening, finalizedCount: 0, lastEvent: nil)
        }
        func finishAndFinalize() async -> RecorderSnapshot {
            RecorderSnapshot(state: .idle, finalizedCount: 0, lastEvent: nil)
        }
        func markInterrupted() async -> RecorderSnapshot {
            RecorderSnapshot(state: .interrupted, finalizedCount: 0, lastEvent: nil)
        }
        func setActiveSource(_ source: AudioSourceType) async {}
        func rollover(to source: AudioSourceType) async -> RecorderSnapshot {
            rolloverCalls.append(source)
            // `Task.sleep` is cancellation-aware and would throw (and return early) the moment
            // `sourceEventTask` is cancelled — defeating the point of this delay (simulating a
            // recorder call genuinely in flight). A plain checked continuation ignores
            // cancellation entirely, so this delay elapses regardless of what performHalt does
            // to the task consuming this call.
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) {
                    continuation.resume()
                }
            }
            return RecorderSnapshot(state: .listening, finalizedCount: 0, lastEvent: nil)
        }
    }

    @Test func stopAfterBufferedSourceChangeEndsIdle() async throws {
        // Regression: `performHalt` used to only CANCEL `sourceEventTask`, never drain it —
        // inert on a `for await` over AsyncStream. A source-change event already in flight
        // when stop() begins (recorder.rollover(to:) + apply(snapshot) reporting .listening)
        // could resolve AFTER finishAndFinalize() set status to .idle, reverting it — a stop()
        // must always leave the pipeline idle for good. `SlowRolloverRecorder`'s artificial
        // delay makes the in-flight window wide and reliable instead of depending on
        // uncontrollable actor-scheduling fairness between two near-instant fakes.
        let omi = FakeConnectableAudioSource()
        let mic = FakeSimpleAudioSource()
        let failover = FailoverAudioSource(omi: omi, phoneMic: mic, config: fastConfig)
        let recorder = SlowRolloverRecorder()
        let pipeline = ListeningPipeline(source: failover, recorder: recorder)
        await pipeline.start()
        await omi.setState(.streaming)
        // Poll rather than a single fixed sleep: this setup step was observed (independent of
        // the regression below) to occasionally need multiple seconds of wall-clock scheduling
        // slack under load — polling stays fast in the common case and still tolerates a slow
        // scheduler without an even longer fixed delay.
        for _ in 0..<150 where pipeline.activeSourceType != .omi {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(pipeline.activeSourceType == .omi)

        await omi.setState(.disconnected)               // arms reconnectGrace (60ms)
        // Let grace fire and phoneMic activate/emit (near-instant), and the pipeline's
        // sourceEventTask start processing that buffered change — its recorder.rollover(to:)
        // call is now sleeping for 150ms, so at the 100ms mark it is reliably still in flight.
        try await Task.sleep(for: .milliseconds(100))
        await pipeline.stop()                           // races the in-flight change vs finalize
        try await Task.sleep(for: .milliseconds(300))
        #expect(pipeline.status == .idle)
        #expect(pipeline.activeSourceType == nil)
        try await Task.sleep(for: .milliseconds(200))   // recheck: must not revert later either
        #expect(pipeline.status == .idle)
        #expect(await recorder.rolloverCalls == [.phoneMic])
    }
}

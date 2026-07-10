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
        let failover = FailoverAudioSource(wearable: omi, phoneMic: mic, config: fastConfig)
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
        // is still exactly one — wearableRecovered schedules nothing.
        #expect(await notifications.sourceFallbackCount == 1)
        await pipeline.stop()
        #expect(pipeline.activeSourceType == nil)
    }

    @Test func captureUnavailableNotifiesLoudly() async throws {
        struct Boom: Error {}
        let omi = FakeConnectableAudioSource()
        let mic = FakeSimpleAudioSource()
        await mic.setStartError(Boom())
        let failover = FailoverAudioSource(wearable: omi, phoneMic: mic, config: fastConfig)
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
        let failover = FailoverAudioSource(wearable: omi, phoneMic: mic, config: fastConfig)
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

    @Test func liveActivitySourceLabelOnlyForSwitchingSources() async throws {
        // M12 Task 12: a plain (non-switching) source still stamps `activeSourceType` as
        // `.phoneMic` (previous test) — the recorder's segment tagging needs that — but the
        // Live Activity must never surface it as a label. Rendering "iPhone mic" on every
        // lock-screen update would be new, unwanted chatter for the vast majority of users
        // who never paired an Omi (mirrors ContentView's `pairedOmiName != nil` gate on the
        // home header).
        let plainMic = FakeAudioSource()
        let plainActivity = FakeLiveActivityController()
        let plainPipeline = ListeningPipeline(
            source: plainMic, recorder: FakeRecorder(stateScript: [1: .recording]),
            liveActivity: plainActivity)
        await plainPipeline.start()
        await plainMic.emitSilentChunks(count: 2)
        await plainMic.finish()
        await plainPipeline.waitUntilDrained()
        #expect(plainActivity.updates.contains { $0.phase == .recording })
        #expect(plainActivity.updates.allSatisfy { $0.sourceLabel == nil })
        await plainPipeline.stop()

        // A switching (Failover) source is the opposite: once a source event lands, the
        // label appears — this IS an Omi-paired session (only FailoverAudioSource conforms
        // to SourceSwitchingAudioSource, and AppModel only builds one when paired).
        let omi = FakeConnectableAudioSource()
        let mic = FakeSimpleAudioSource()
        let failover = FailoverAudioSource(wearable: omi, phoneMic: mic, config: fastConfig)
        let switchingActivity = FakeLiveActivityController()
        let switchingPipeline = ListeningPipeline(
            source: failover, recorder: FakeRecorder(), liveActivity: switchingActivity)
        await switchingPipeline.start()
        await omi.setState(.streaming)
        try await Task.sleep(for: .milliseconds(60))
        #expect(switchingActivity.updates.contains { $0.sourceLabel == "Omi" })
        await switchingPipeline.stop()
    }

    @Test func repeatFallbackEventDoesNotDoubleNotify() async throws {
        // Regression for the RACE B repeat: FailoverAudioSource can emit the SAME source
        // (.phoneMic/.wearableDisconnected) twice in a row with no intervening recovery, when the
        // Omi drops again during a suspended phoneMic.stop() mid-return-hysteresis. The
        // pipeline must still roll the recorder over both times (harmless no-op finalize) but
        // must only fire the user-facing notification once.
        //
        // Widened window (M12 final review Important #3): a dedicated config (not the shared
        // `fastConfig`) pushes returnHysteresis to 300ms (mic stop delay to 600ms) with the
        // sleep landing at 350ms — 50ms past the hysteresis boundary, comfortably inside the
        // [300, 900] window instead of 90ms inside the shared fastConfig's [80, 230].
        // Implementation timing is untouched; only this test's fake config/delay widen.
        let config = FailoverConfig(
            startupRace: .milliseconds(60), reconnectGrace: .milliseconds(60),
            returnHysteresis: .milliseconds(300))
        let omi = FakeConnectableAudioSource()
        let mic = FakeSimpleAudioSource()
        let failover = FailoverAudioSource(wearable: omi, phoneMic: mic, config: config)
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
        await mic.setStopDelay(600)
        await omi.setState(.streaming)                      // arms the 300 ms return-hysteresis
        try await Task.sleep(for: .milliseconds(350))       // hysteresis fires; phoneMic.stop() suspended
        await omi.setState(.disconnected)                   // omi drops again mid-suspended-stop
        try await Task.sleep(for: .milliseconds(700))       // let everything settle

        #expect(pipeline.activeSourceType == .phoneMic)
        // Still exactly one fallback notification despite the repeat .wearableDisconnected event.
        #expect(await notifications.sourceFallbackCount == 1)
        // The recorder DID see the repeat rollover call (harmless no-op finalize-wise).
        #expect(await recorder.rolloverCalls.filter { $0 == .phoneMic }.count >= 2)
        await pipeline.stop()
    }

    /// Polls `condition` every 20ms until it holds or `timeout` elapses; returns whether it
    /// was ultimately met. Deterministic setup waits instead of fixed sleeps: the happy path
    /// stays fast, and a scheduler starved by full-suite load can't flake a precondition.
    @discardableResult
    private func waitUntil(timeout: Duration = .seconds(3),
                           _ condition: @MainActor () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await condition()
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
        let failover = FailoverAudioSource(wearable: omi, phoneMic: mic, config: fastConfig)
        let recorder = SlowRolloverRecorder()
        let pipeline = ListeningPipeline(source: failover, recorder: recorder)
        await pipeline.start()
        await omi.setState(.streaming)
        // Deterministic setup wait (not a fixed sleep): relies on start() subscribing to
        // sourceChanges() BEFORE source.start() — with the old subscribe-after-start order,
        // this first activation event could be emitted to zero continuations and lost forever,
        // making no wait long enough (the root cause of a rare setup flake under load).
        let sawOmi = await waitUntil { pipeline.activeSourceType == .omi }
        #expect(sawOmi, "setup: pipeline never observed .omi as the active source")
        #expect(pipeline.activeSourceType == .omi)

        await omi.setState(.disconnected)               // arms reconnectGrace (60ms)
        // Grace fires -> phoneMic activates -> .wearableDisconnected emitted -> pipeline's
        // handleSourceChange enters recorder.rollover(to:), which appends to rolloverCalls
        // FIRST and then blocks for 150ms. Waiting on the append (20ms poll) instead of a
        // fixed sleep guarantees stop() lands while the change is genuinely in flight, with
        // >=130ms of margin left in the rollover delay.
        let rolloverInFlight = await waitUntil { !(await recorder.rolloverCalls.isEmpty) }
        #expect(rolloverInFlight, "setup: rollover never started after Omi disconnect")
        await pipeline.stop()                           // races the in-flight change vs finalize
        try await Task.sleep(for: .milliseconds(300))   // observation window, not a setup wait:
        #expect(pipeline.status == .idle)               // a revert would land in here pre-fix
        #expect(pipeline.activeSourceType == nil)
        try await Task.sleep(for: .milliseconds(200))   // recheck: must not revert later either
        #expect(pipeline.status == .idle)
        #expect(await recorder.rolloverCalls == [.phoneMic])
    }
}

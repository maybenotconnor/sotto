import Testing
@testable import Sotto

@MainActor
struct InterruptionTests {
    @Test func interruptHaltsAndParks() async throws {
        let source = FakeAudioSource()
        let recorder = FakeRecorder()
        let activity = FakeLiveActivityController()
        let pipeline = ListeningPipeline(
            source: source, recorder: recorder, liveActivity: activity)

        await pipeline.start()
        await source.emitSilentChunks(count: 2)
        await pipeline.interrupt()

        #expect(pipeline.status == .interrupted)
        #expect(await recorder.markInterruptedCount == 1)
        #expect(await recorder.processedAfterFinish == 0)      // drained before parking
        #expect(await source.stopCallCount == 1)               // engine torn down
        #expect(activity.updates.last?.phase == .pausedBySystem)
        #expect(activity.endedCount == 0)                      // activity survives interruption
    }

    @Test func interruptWhenIdleIsNoOp() async throws {
        let recorder = FakeRecorder()
        let pipeline = ListeningPipeline(
            source: FakeAudioSource(), recorder: recorder, liveActivity: nil)
        await pipeline.interrupt()
        #expect(pipeline.status == .idle)
        #expect(await recorder.markInterruptedCount == 0)
    }

    @Test func resumeFromInterruptionRestartsCleanly() async throws {
        let source = FakeAudioSource()
        let recorder = FakeRecorder()
        let activity = FakeLiveActivityController()
        let pipeline = ListeningPipeline(
            source: source, recorder: recorder, liveActivity: activity)

        await pipeline.start()
        await pipeline.interrupt()
        await pipeline.resumeFromInterruption()

        #expect(pipeline.status == .listening)
        #expect(await source.startCallCount == 2)
        #expect(await source.stopCallCount >= 2)               // defensive stop before restart
        #expect(await recorder.beginCount == 2)
        #expect(activity.updates.last?.phase == .listening)
    }

    @Test func resumeWhenNotInterruptedIsNoOp() async throws {
        let source = FakeAudioSource()
        let pipeline = ListeningPipeline(
            source: source, recorder: FakeRecorder(), liveActivity: nil)
        await pipeline.start()
        await pipeline.resumeFromInterruption()                // listening, not interrupted
        #expect(pipeline.status == .listening)
        #expect(await source.startCallCount == 1)
        await pipeline.stop()
    }

    @Test func stopFromInterruptedGoesIdleAndEndsActivity() async throws {
        let source = FakeAudioSource()
        let activity = FakeLiveActivityController()
        let pipeline = ListeningPipeline(
            source: source, recorder: FakeRecorder(), liveActivity: activity)

        await pipeline.start()
        await pipeline.interrupt()
        await pipeline.stop()

        #expect(pipeline.status == .idle)
        #expect(activity.endedCount == 1)
    }

    @Test func interruptDuringStartIsHonoredAfterStartCompletes() async throws {
        let source = SlowStartAudioSource()
        let recorder = FakeRecorder()
        let pipeline = ListeningPipeline(
            source: source, recorder: recorder, liveActivity: nil)

        async let starting: Void = pipeline.start()
        await source.waitUntilStartRequested()
        await pipeline.interrupt()                             // mid-start: pends, returns
        await source.releaseStart()
        await starting

        #expect(pipeline.status == .interrupted)
        #expect(await recorder.markInterruptedCount == 1)
    }

    @Test func queuedStopBeatsPendingInterrupt() async throws {
        let source = SlowStartAudioSource()
        let recorder = FakeRecorder()
        let pipeline = ListeningPipeline(
            source: source, recorder: recorder, liveActivity: nil)

        async let starting: Void = pipeline.start()
        await source.waitUntilStartRequested()
        await pipeline.interrupt()                             // pends
        async let stopping: Void = pipeline.stop()             // queues (stop wins)
        for _ in 0..<5 { await Task.yield() }
        await source.releaseStart()
        _ = await (starting, stopping)

        #expect(pipeline.status == .idle)                      // stop won
        #expect(await recorder.finishCount == 1)
        #expect(await recorder.markInterruptedCount == 0)
    }

    @Test func toggleFromIntentCoversAllThreeStates() async throws {
        let source = FakeAudioSource()
        let pipeline = ListeningPipeline(
            source: source, recorder: FakeRecorder(), liveActivity: nil)

        await pipeline.toggleFromIntent()                      // idle → start
        #expect(pipeline.status == .listening)
        await pipeline.interrupt()
        await pipeline.toggleFromIntent()                      // interrupted → resume
        #expect(pipeline.status == .listening)
        await pipeline.toggleFromIntent()                      // active → pause by user (not stop)
        #expect(pipeline.status == .interrupted)
        #expect(pipeline.haltReason == .userPause)
    }

    @Test func stopQueuedDuringInterruptHaltStillFullyStops() async throws {
        let source = FakeAudioSource()
        let recorder = FakeRecorder()
        let activity = FakeLiveActivityController()
        let pipeline = ListeningPipeline(
            source: source, recorder: recorder, liveActivity: activity)

        await pipeline.start()
        // Race an interrupt-halt against a stop. If the stop queues mid-halt (the bug's
        // window), it must still leave the pipeline idle+finalized when it returns; if it
        // happens to win the race outright, the interrupt no-ops from idle — either
        // ordering must satisfy the assertions.
        async let interrupting: Void = pipeline.interrupt()
        async let stopping: Void = pipeline.stop()
        _ = await (interrupting, stopping)

        #expect(pipeline.status == .idle)
        #expect(await recorder.finishCount == 1)
        #expect(activity.endedCount == 1)
    }

    @Test func interruptPendedDuringStopHaltDoesNotHijackNextStart() async throws {
        let source = FakeAudioSource()
        let recorder = FakeRecorder()
        let pipeline = ListeningPipeline(
            source: source, recorder: recorder, liveActivity: nil)

        await pipeline.start()
        async let stopping: Void = pipeline.stop()
        async let interrupting: Void = pipeline.interrupt()   // pends mid-halt, or no-ops from idle
        _ = await (stopping, interrupting)
        #expect(pipeline.status == .idle)

        await pipeline.start()                                // a fresh, unrelated session
        #expect(pipeline.status == .listening)                // must NOT be hijacked to .interrupted
        // NOTE: no assertion on markInterruptedCount — in the (legal) ordering where the
        // interrupt wins the initial race outright, the counter is 1 while the hijack
        // property above still holds; the counter would make this test order-fragile.
        await pipeline.stop()
    }

    @Test func interruptSchedulesFallbackNotificationAndResumeCancelsIt() async throws {
        let source = FakeAudioSource()
        let notifications = FakeNotificationScheduler()
        let pipeline = ListeningPipeline(
            source: source, recorder: FakeRecorder(),
            liveActivity: nil, notifications: notifications)

        await pipeline.start()
        #expect(await notifications.authorizationRequests == 1)
        await pipeline.interrupt()
        #expect(await notifications.scheduled == 1)            // scheduled on .began, per spec
        await pipeline.resumeFromInterruption()
        #expect(await notifications.cancelled == 1)
    }

    @Test func interruptDuringResumeIsHonoredEvenAfterChunkAdvancesStatus() async throws {
        let source = FakeAudioSource()
        let recorder = FakeRecorder(stateScript: [0: .recording])   // first chunk → .recording
        let notifications = GatedNotificationScheduler()
        let pipeline = ListeningPipeline(
            source: source, recorder: recorder, liveActivity: nil, notifications: notifications)

        await pipeline.start()
        await pipeline.interrupt()
        async let resuming: Void = pipeline.resumeFromInterruption()
        await notifications.waitUntilCancelRequested()      // resume is suspended mid-transition
        await source.emitSilentChunks(count: 1)
        for _ in 0..<10 { await Task.yield() }              // let the pump advance status to .recording
        await pipeline.interrupt()                          // must PEND (isTransitioning true)
        await notifications.releaseCancel()
        await resuming

        #expect(pipeline.status == .interrupted)            // pended interrupt honored, not dropped
    }

    @Test func pauseByUserParksWithoutFallbackNotification() async throws {
        let source = FakeAudioSource()
        let notifications = FakeNotificationScheduler()
        let activity = FakeLiveActivityController()
        let pipeline = ListeningPipeline(
            source: source, recorder: FakeRecorder(),
            liveActivity: activity, notifications: notifications)

        await pipeline.start()
        await pipeline.pauseByUser()

        #expect(pipeline.status == .interrupted)
        #expect(pipeline.haltReason == .userPause)
        #expect(await notifications.scheduled == 0)          // user chose this; no "resume" nag
        #expect(activity.updates.last?.phase == .pausedByUser)
        #expect(activity.endedCount == 0)                    // activity survives — Resume works

        await pipeline.resumeFromInterruption()
        #expect(pipeline.status == .listening)
        #expect(pipeline.haltReason == nil)
    }

    @Test func systemInterruptionStillSchedulesNotification() async throws {
        let source = FakeAudioSource()
        let notifications = FakeNotificationScheduler()
        let pipeline = ListeningPipeline(
            source: source, recorder: FakeRecorder(),
            liveActivity: nil, notifications: notifications)
        await pipeline.start()
        await pipeline.interrupt()
        #expect(pipeline.haltReason == .systemInterruption)
        #expect(await notifications.scheduled == 1)
    }

    @Test func userPauseDuringStartKeepsUserPauseSemantics() async throws {
        let source = SlowStartAudioSource()
        let notifications = FakeNotificationScheduler()
        let pipeline = ListeningPipeline(
            source: source, recorder: FakeRecorder(),
            liveActivity: nil, notifications: notifications)

        async let starting: Void = pipeline.start()
        await source.waitUntilStartRequested()
        await pipeline.pauseByUser()                 // mid-start: must pend as USER pause
        await source.releaseStart()
        await starting

        #expect(pipeline.status == .interrupted)
        #expect(pipeline.haltReason == .userPause)   // not mislabeled as a call
        #expect(await notifications.scheduled == 0)  // and no spurious fallback notification
    }

    @Test func sessionStartedAtTracksLifecycle() async throws {
        let pipeline = ListeningPipeline(source: FakeAudioSource(), recorder: FakeRecorder())
        #expect(pipeline.sessionStartedAt == nil)
        await pipeline.start()
        #expect(pipeline.sessionStartedAt != nil)
        await pipeline.stop()
        #expect(pipeline.sessionStartedAt == nil)
    }
}

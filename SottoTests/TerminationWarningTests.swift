import Foundation
import Testing
@testable import Sotto

/// Force-quit warning (2026-08-04 field incident): iOS delivers `applicationWillTerminate`
/// with a ~5 s grace window when a *running* app is swiped away in the app switcher, and a
/// force-quit app is barred from BLE state restoration — so this last-gasp notification is
/// the ONLY signal the user ever gets that recording died with the app.
@MainActor
struct TerminationWarningTests {
    @Test func warnsWhenTerminatedWhileCapturing() async throws {
        let mic = FakeSimpleAudioSource()
        let notifications = FakeNotificationScheduler()
        let pipeline = ListeningPipeline(source: mic, recorder: FakeRecorder(),
                                         notifications: notifications)
        await pipeline.start()
        #expect(pipeline.activeSourceType == .phoneMic)

        await pipeline.appWillTerminate()
        #expect(await notifications.closedWhileRecordingCount == 1)
        await pipeline.stop()
    }

    @Test func noWarningWhenIdle() async throws {
        let notifications = FakeNotificationScheduler()
        let pipeline = ListeningPipeline(source: FakeSimpleAudioSource(),
                                         recorder: FakeRecorder(),
                                         notifications: notifications)
        await pipeline.appWillTerminate()
        #expect(await notifications.closedWhileRecordingCount == 0)
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
        let notifications = FakeNotificationScheduler()
        let pipeline = ListeningPipeline(source: failover, recorder: FakeRecorder(),
                                         notifications: notifications)
        await pipeline.start()
        try await Task.sleep(for: .milliseconds(100))
        #expect(pipeline.isWaitingForCapture)

        await pipeline.appWillTerminate()
        #expect(await notifications.closedWhileRecordingCount == 0)
        await pipeline.stop()
    }

    @Test func noWarningWhenInterrupted() async throws {
        // A parked session already delivered the "Sotto was paused" notification; the user
        // has been told recording is not running.
        let mic = FakeSimpleAudioSource()
        let notifications = FakeNotificationScheduler()
        let pipeline = ListeningPipeline(source: mic, recorder: FakeRecorder(),
                                         notifications: notifications)
        await pipeline.start()
        await pipeline.interrupt()
        #expect(pipeline.status == .interrupted)

        await pipeline.appWillTerminate()
        #expect(await notifications.closedWhileRecordingCount == 0)
        await pipeline.stop()
    }
}

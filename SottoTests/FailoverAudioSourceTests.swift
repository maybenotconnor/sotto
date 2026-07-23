import Foundation
import Testing
@testable import Sotto

struct FailoverAudioSourceTests {
    private let fastConfig = FailoverConfig(
        reconnectGrace: .milliseconds(80),
        returnHysteresis: .milliseconds(120))
    /// For asserting IMMEDIATE transitions: if the implementation wrongly applied the
    /// hysteresis, the change would take 5 s and the elapsed-time assertion fails.
    private let slowReturnConfig = FailoverConfig(
        reconnectGrace: .milliseconds(80),
        returnHysteresis: .seconds(5))

    private func makeChunk(_ value: Float = 0.5) -> AudioChunk {
        AudioChunk(samples: [Float](repeating: value, count: 4096), hostTime: 1)
    }

    private func collectChanges(_ source: FailoverAudioSource) async -> AsyncStream<AudioSourceChange>.AsyncIterator {
        await source.sourceChanges().makeAsyncIterator()
    }

    @Test func micActivatesImmediatelyOnStart() async throws {
        let omi = FakeConnectableAudioSource()
        let mic = FakeSimpleAudioSource()
        let failover = FailoverAudioSource(wearable: omi, phoneMic: mic, config: fastConfig)
        var changes = await collectChanges(failover)
        let stream = try await failover.start()
        #expect(await changes.next() == AudioSourceChange(source: .phoneMic, reason: .initial))
        #expect(await mic.startCount == 1)
        await mic.emitChunk(makeChunk())
        var it = stream.makeAsyncIterator()
        #expect(await it.next()?.samples.count == 4096)
        await failover.stop()
    }

    @Test func startWithThrowingMicEntersWaitingWithoutThrowing() async throws {
        struct Boom: Error {}
        let omi = FakeConnectableAudioSource()
        let mic = FakeSimpleAudioSource()
        await mic.setStartError(Boom())
        let failover = FailoverAudioSource(wearable: omi, phoneMic: mic, config: fastConfig)
        var changes = await collectChanges(failover)
        _ = try await failover.start()   // must NOT throw (spec §1)
        #expect(await changes.next() == AudioSourceChange(source: nil, reason: .captureUnavailable))
        #expect(await failover.activeSourceType == nil)
        #expect(await omi.startCount == 1)   // the wearable side stays armed
        await failover.stop()
    }

    @Test func firstStreamingUpgradesImmediately() async throws {
        let omi = FakeConnectableAudioSource()
        let mic = FakeSimpleAudioSource()
        let failover = FailoverAudioSource(wearable: omi, phoneMic: mic, config: slowReturnConfig)
        var changes = await collectChanges(failover)
        _ = try await failover.start()
        #expect(await changes.next()?.source == .phoneMic)
        let clock = ContinuousClock()
        let t0 = clock.now
        await omi.setState(.streaming)
        #expect(await changes.next() == AudioSourceChange(source: .omi, reason: .wearableRecovered))
        #expect(clock.now - t0 < .seconds(1))   // immediate, not the 5 s hysteresis
        #expect(await mic.stopCount >= 1)
        await failover.stop()
    }

    @Test func rescueFromWaitingIsImmediate() async throws {
        struct Boom: Error {}
        let omi = FakeConnectableAudioSource()
        let mic = FakeSimpleAudioSource()
        await mic.setStartError(Boom())
        let failover = FailoverAudioSource(wearable: omi, phoneMic: mic, config: slowReturnConfig)
        var changes = await collectChanges(failover)
        _ = try await failover.start()
        #expect(await changes.next()?.reason == .captureUnavailable)
        let clock = ContinuousClock()
        let t0 = clock.now
        await omi.setState(.streaming)
        #expect(await changes.next() == AudioSourceChange(source: .omi, reason: .initial))
        #expect(clock.now - t0 < .seconds(1))   // hysteresis never delays zero-capture rescue
        await failover.stop()
    }

    @Test func postFailureReturnWaitsHysteresis() async throws {
        let omi = FakeConnectableAudioSource()
        let mic = FakeSimpleAudioSource()
        let failover = FailoverAudioSource(wearable: omi, phoneMic: mic, config: fastConfig)
        var changes = await collectChanges(failover)
        _ = try await failover.start()
        #expect(await changes.next()?.source == .phoneMic)      // mic-first
        await omi.setState(.streaming)
        #expect(await changes.next()?.source == .omi)           // first upgrade, immediate
        await omi.setState(.disconnected)
        #expect(await changes.next() == AudioSourceChange(source: .phoneMic, reason: .wearableDisconnected))
        await omi.setState(.streaming)                          // returned after a failure
        try await Task.sleep(for: .milliseconds(30))            // < 120 ms hysteresis
        #expect(await failover.activeSourceType == .phoneMic)   // still proving itself
        #expect(await changes.next() == AudioSourceChange(source: .omi, reason: .wearableRecovered))
        await failover.stop()
    }

    @Test func blipWithinGraceDoesNotSwitch() async throws {
        // Widened window (M12 final review Important #3 precedent): 300 ms grace with the
        // blip at 50 ms — comfortably inside, immune to scheduler load.
        let config = FailoverConfig(
            reconnectGrace: .milliseconds(300), returnHysteresis: .milliseconds(300))
        let omi = FakeConnectableAudioSource()
        let mic = FakeSimpleAudioSource()
        let failover = FailoverAudioSource(wearable: omi, phoneMic: mic, config: config)
        var changes = await collectChanges(failover)
        _ = try await failover.start()
        #expect(await changes.next()?.source == .phoneMic)
        await omi.setState(.streaming)
        #expect(await changes.next()?.source == .omi)
        await omi.setState(.disconnected)
        try await Task.sleep(for: .milliseconds(50))     // well inside the 300 ms grace
        await omi.setState(.streaming)
        try await Task.sleep(for: .milliseconds(350))    // past the grace duration
        #expect(await mic.startCount == 1)               // never re-fell-back (1 = mic-first start)
        #expect(await failover.activeSourceType == .omi)
        await failover.stop()
    }

    @Test func flapDuringHysteresisCancelsReturn() async throws {
        let omi = FakeConnectableAudioSource()
        let mic = FakeSimpleAudioSource()
        let failover = FailoverAudioSource(wearable: omi, phoneMic: mic, config: fastConfig)
        var changes = await collectChanges(failover)
        _ = try await failover.start()
        #expect(await changes.next()?.source == .phoneMic)
        await omi.setState(.streaming)
        #expect(await changes.next()?.source == .omi)           // first upgrade
        await omi.setState(.disconnected)
        #expect(await changes.next()?.source == .phoneMic)      // grace expired → mic
        await omi.setState(.streaming)
        try await Task.sleep(for: .milliseconds(30))            // < 120 ms hysteresis
        await omi.setState(.disconnected)                       // flap: cancels the return
        try await Task.sleep(for: .milliseconds(250))
        #expect(await failover.activeSourceType == .phoneMic)
        await failover.stop()
    }

    @Test func stopDuringDelayedMicStartLeavesNoOrphanCapture() async throws {
        let omi = FakeConnectableAudioSource()
        let mic = FakeSimpleAudioSource()
        await mic.setStartDelay(150)
        let failover = FailoverAudioSource(wearable: omi, phoneMic: mic, config: fastConfig)
        let startTask = Task { _ = try await failover.start() }
        try await Task.sleep(for: .milliseconds(50))    // inside the suspended inline mic start
        await failover.stop()
        _ = try? await startTask.value
        try await Task.sleep(for: .milliseconds(250))
        #expect(await mic.stopCount >= 1)               // orphaned start undone (RACE A)
        #expect(await failover.activeSourceType == nil)
    }

    @Test func omiDropDuringDelayedMicStopRestartsMic() async throws {
        let omi = FakeConnectableAudioSource()
        let mic = FakeSimpleAudioSource()
        let failover = FailoverAudioSource(wearable: omi, phoneMic: mic, config: fastConfig)
        var changes = await collectChanges(failover)
        _ = try await failover.start()
        #expect(await changes.next()?.source == .phoneMic)
        await mic.setStopDelay(100)
        await omi.setState(.streaming)                  // first upgrade suspends on mic.stop()
        try await Task.sleep(for: .milliseconds(30))
        await omi.setState(.disconnected)               // drops during the suspension (RACE B)
        let change = await changes.next()
        #expect(change?.source == .phoneMic)            // mic restarted, not a dead-omi claim
        #expect(await failover.activeSourceType == .phoneMic)
        await failover.stop()
    }

    @Test func stopContractHolds() async throws {
        let omi = FakeConnectableAudioSource()
        let mic = FakeSimpleAudioSource()
        let failover = FailoverAudioSource(wearable: omi, phoneMic: mic, config: fastConfig)
        let stream = try await failover.start()
        await failover.stop()
        await failover.stop()   // idempotent
        var it = stream.makeAsyncIterator()
        #expect(await it.next() == nil)   // stream finished on stop
    }
}

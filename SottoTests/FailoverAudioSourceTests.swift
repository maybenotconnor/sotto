import Foundation
import Testing
@testable import Sotto

struct FailoverAudioSourceTests {
    private let fastConfig = FailoverConfig(
        startupRace: .milliseconds(80),
        reconnectGrace: .milliseconds(80),
        returnHysteresis: .milliseconds(120))

    private func makeChunk(_ value: Float = 0.5) -> AudioChunk {
        AudioChunk(samples: [Float](repeating: value, count: 4096), hostTime: 1)
    }

    /// Collects change events into an actor-safe box for assertions.
    private func collectChanges(_ source: FailoverAudioSource) async -> AsyncStream<AudioSourceChange>.AsyncIterator {
        await source.sourceChanges().makeAsyncIterator()
    }

    @Test func omiWinsStartupRaceWhenStreaming() async throws {
        let omi = FakeConnectableAudioSource()
        let mic = FakeSimpleAudioSource()
        let failover = FailoverAudioSource(omi: omi, phoneMic: mic, config: fastConfig)
        var changes = await collectChanges(failover)
        let stream = try await failover.start()
        await omi.setState(.streaming)
        #expect(await changes.next() == AudioSourceChange(source: .omi, reason: .initial))
        await omi.emitChunk(makeChunk())
        var it = stream.makeAsyncIterator()
        #expect(await it.next()?.samples.count == 4096)
        #expect(await mic.startCount == 0)   // phone mic never touched
        await failover.stop()
    }

    @Test func phoneMicWinsWhenOmiSilentPastRace() async throws {
        let omi = FakeConnectableAudioSource()
        let mic = FakeSimpleAudioSource()
        let failover = FailoverAudioSource(omi: omi, phoneMic: mic, config: fastConfig)
        var changes = await collectChanges(failover)
        let stream = try await failover.start()
        // No omi streaming within 80 ms:
        #expect(await changes.next() == AudioSourceChange(source: .phoneMic, reason: .initial))
        await mic.emitChunk(makeChunk())
        var it = stream.makeAsyncIterator()
        #expect(await it.next() != nil)
        await failover.stop()
    }

    @Test func disconnectPastGraceFallsBackAndRecoveryReturns() async throws {
        let omi = FakeConnectableAudioSource()
        let mic = FakeSimpleAudioSource()
        let failover = FailoverAudioSource(omi: omi, phoneMic: mic, config: fastConfig)
        var changes = await collectChanges(failover)
        _ = try await failover.start()
        await omi.setState(.streaming)
        #expect(await changes.next()?.reason == .initial)

        await omi.setState(.disconnected)
        #expect(await changes.next() == AudioSourceChange(source: .phoneMic, reason: .omiDisconnected))

        await omi.setState(.streaming)          // stays stable through hysteresis
        #expect(await changes.next() == AudioSourceChange(source: .omi, reason: .omiRecovered))
        #expect(await mic.stopCount >= 1)
        await failover.stop()
    }

    @Test func blipWithinGraceDoesNotSwitch() async throws {
        let omi = FakeConnectableAudioSource()
        let mic = FakeSimpleAudioSource()
        let failover = FailoverAudioSource(omi: omi, phoneMic: mic, config: fastConfig)
        var changes = await collectChanges(failover)
        _ = try await failover.start()
        await omi.setState(.streaming)
        #expect(await changes.next()?.reason == .initial)
        await omi.setState(.disconnected)
        try await Task.sleep(for: .milliseconds(20))     // < 80 ms grace
        await omi.setState(.streaming)
        try await Task.sleep(for: .milliseconds(200))
        #expect(await mic.startCount == 0)               // never fell back
        await failover.stop()
    }

    @Test func flapDuringHysteresisCancelsReturn() async throws {
        let omi = FakeConnectableAudioSource()
        let mic = FakeSimpleAudioSource()
        let failover = FailoverAudioSource(omi: omi, phoneMic: mic, config: fastConfig)
        var changes = await collectChanges(failover)
        _ = try await failover.start()
        await omi.setState(.streaming)
        _ = await changes.next()                          // initial
        await omi.setState(.disconnected)
        _ = await changes.next()                          // omiDisconnected
        await omi.setState(.streaming)
        try await Task.sleep(for: .milliseconds(30))      // < 120 ms hysteresis
        await omi.setState(.disconnected)                 // flap: cancels the return
        try await Task.sleep(for: .milliseconds(250))
        #expect(await failover.activeSourceType == .phoneMic)
        await failover.stop()
    }

    @Test func micFailureEmitsCaptureUnavailableThenOmiRecovers() async throws {
        struct Boom: Error {}
        let omi = FakeConnectableAudioSource()
        let mic = FakeSimpleAudioSource()
        await mic.setStartError(Boom())
        let failover = FailoverAudioSource(omi: omi, phoneMic: mic, config: fastConfig)
        var changes = await collectChanges(failover)
        _ = try await failover.start()
        await omi.setState(.streaming)
        _ = await changes.next()                          // initial
        await omi.setState(.disconnected)
        #expect(await changes.next() == AudioSourceChange(source: nil, reason: .captureUnavailable))
        await omi.setState(.streaming)
        #expect(await changes.next() == AudioSourceChange(source: .omi, reason: .omiRecovered))
        await failover.stop()
    }

    @Test func stopDuringDelayedMicStartLeavesNoOrphanCapture() async throws {
        let omi = FakeConnectableAudioSource()
        let mic = FakeSimpleAudioSource()
        let failover = FailoverAudioSource(omi: omi, phoneMic: mic, config: fastConfig)
        // Collect every change event from the start so we can assert none arrived after stop.
        let changeStream = await failover.sourceChanges()
        let collected = Task<[AudioSourceChange], Never> {
            var events: [AudioSourceChange] = []
            for await change in changeStream { events.append(change) }
            return events
        }
        await mic.setStartDelay(150)
        _ = try await failover.start()
        await omi.setState(.streaming)
        await omi.setState(.disconnected)          // arms the 80 ms grace timer
        try await Task.sleep(for: .milliseconds(130))   // grace (80ms) fires; mic.start() now suspended
        await failover.stop()
        try await Task.sleep(for: .milliseconds(200))   // let the delayed (150ms) start fully resolve
        #expect(await mic.stopCount >= (await mic.startCount))
        #expect(await failover.activeSourceType == nil)
        let events = await collected.value
        #expect(!events.contains { $0.source == .phoneMic })
    }

    @Test func omiDropDuringDelayedMicStopRestartsMic() async throws {
        let omi = FakeConnectableAudioSource()
        let mic = FakeSimpleAudioSource()
        let failover = FailoverAudioSource(omi: omi, phoneMic: mic, config: fastConfig)
        var changes = await collectChanges(failover)
        _ = try await failover.start()
        await omi.setState(.streaming)
        #expect(await changes.next()?.reason == .initial)
        await omi.setState(.disconnected)
        #expect(await changes.next() == AudioSourceChange(source: .phoneMic, reason: .omiDisconnected))
        await mic.setStopDelay(150)
        await omi.setState(.streaming)              // arms the 120 ms return-hysteresis timer
        try await Task.sleep(for: .milliseconds(160))   // hysteresis (120ms) fires; phoneMic.stop() suspended
        await omi.setState(.disconnected)               // omi drops during the suspended stop
        try await Task.sleep(for: .milliseconds(350))   // let everything settle
        #expect(await failover.activeSourceType == .phoneMic)
        await failover.stop()
    }

    @Test func stopContractHolds() async throws {
        let omi = FakeConnectableAudioSource()
        let mic = FakeSimpleAudioSource()
        let failover = FailoverAudioSource(omi: omi, phoneMic: mic, config: fastConfig)
        await failover.stop()                              // safe unstarted
        let stream = try await failover.start()
        await failover.stop()
        var it = stream.makeAsyncIterator()
        #expect(await it.next() == nil)                   // stream finished
        await failover.stop()                              // idempotent
        _ = try await failover.start()                     // restartable
        await failover.stop()
    }
}

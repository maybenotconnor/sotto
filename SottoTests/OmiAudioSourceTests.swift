import Foundation
import Testing
@testable import Sotto

struct OmiAudioSourceTests {
    private func makeSource() -> (OmiAudioSource, FakeOmiTransport) {
        let transport = FakeOmiTransport()
        let source = OmiAudioSource(transport: transport, deviceID: UUID())
        return (source, transport)
    }

    /// Feeds `sampleCount` PCM16 samples of value 0x0100 (Float ≈ 0.0078) as sequential
    /// single-fragment notifications of 160 samples each, then one trailing notification
    /// (the assembler holds the last frame until the next arrives).
    private func feedSamples(_ transport: FakeOmiTransport, from packet: UInt16, count: Int) async {
        // The assembler holds the newest frame until the NEXT packet# arrives, so to get
        // ≥ count samples through, send enough notifications that the FLUSHED frames
        // (sent − 1) cover count: e.g. count 4096 → 25 full frames isn't enough (4000),
        // 26 flushed frames = 4160 ≥ 4096 → send 27 notifications.
        let flushedFramesNeeded = (count + 159) / 160 + 1   // ceil + slack for the held frame
        for i in 0...flushedFramesNeeded {
            let payload = [UInt8](repeating: 0, count: 160 * 2).enumerated()
                .map { (offset, _) in offset % 2 == 1 ? UInt8(0x01) : UInt8(0x00) }
            await transport.emitAudio(packet: packet &+ UInt16(i), payload: payload)
        }
    }

    @Test func chunksFlowAfterConnectAndAudio() async throws {
        let (source, transport) = makeSource()
        let stream = try await source.start()
        await transport.emit(.connecting)
        await transport.emit(.connected(codecValue: OmiConstants.codecPCM16at16kHz))
        await feedSamples(transport, from: 0, count: 4096)

        var iterator = stream.makeAsyncIterator()
        let chunk = await iterator.next()
        #expect(chunk?.samples.count == 4096)
        #expect(abs((chunk?.samples[0] ?? 0) - Float(0x0100) / 32_768.0) < 0.0001)
        await source.stop()
    }

    @Test func connectionStatesProgressToStreaming() async throws {
        let (source, transport) = makeSource()
        let states = await source.connectionStates()
        _ = try await source.start()
        var iterator = states.makeAsyncIterator()

        await transport.emit(.connecting)
        #expect(await iterator.next() == .connecting)
        await transport.emit(.connected(codecValue: OmiConstants.codecOpusAt16kHz))
        #expect(await iterator.next() == .connected)
        await transport.emitAudio(packet: 0, payload: [0x00])
        #expect(await iterator.next() == .streaming)     // first audio ⇒ streaming
        await transport.emit(.disconnected)
        #expect(await iterator.next() == .disconnected)
        await source.stop()
    }

    @Test func unsupportedCodecSurfacesFailureAndNeverStreams() async throws {
        let (source, transport) = makeSource()
        let states = await source.connectionStates()
        _ = try await source.start()
        var iterator = states.makeAsyncIterator()
        await transport.emit(.connected(codecValue: OmiConstants.codecPCM16at8kHz))
        #expect(await iterator.next() == .connected)
        await transport.emitAudio(packet: 0, payload: [0x00, 0x00])
        // No .streaming state, and the failure is legible for Settings:
        let message = await source.setupFailureMessage
        #expect(message?.contains("codec") == true)
        await source.stop()
    }

    @Test func batteryLevelsStreamAndLatestIsStored() async throws {
        let (source, transport) = makeSource()
        let levels = await source.batteryLevels()
        _ = try await source.start()
        var iterator = levels.makeAsyncIterator()
        await transport.emit(.batteryLevel(80))
        #expect(await iterator.next() == 80)
        await source.stop()
    }

    @Test func stopContractHolds() async throws {
        let (source, transport) = makeSource()
        // Safe when never started:
        await source.stop()
        // Finishes the stream:
        let stream = try await source.start()
        await source.stop()
        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next() == nil)
        // Idempotent:
        await source.stop()
        #expect(await transport.stopEventsCallCount >= 1)
        // Restartable (resumeFromInterruption calls stop() then start()):
        let stream2 = try await source.start()
        await transport.emit(.connected(codecValue: OmiConstants.codecPCM16at16kHz))
        await feedSamples(transport, from: 0, count: 4096)
        var iterator2 = stream2.makeAsyncIterator()
        #expect(await iterator2.next() != nil)
        await source.stop()
    }

    @Test func stopFinishesConnectionStateAndBatteryStreams() async throws {
        let (source, transport) = makeSource()
        let states = await source.connectionStates()
        let levels = await source.batteryLevels()
        _ = try await source.start()
        await transport.emit(.connecting)
        await source.stop()

        var stateIterator = states.makeAsyncIterator()
        // stop() drains buffered straggler events (the .connecting) BEFORE its terminal
        // yield, then finishes every observer continuation — so an iterator resumed only
        // AFTER stop() returns sees the full, ended sequence rather than hanging.
        #expect(await stateIterator.next() == .connecting)
        #expect(await stateIterator.next() == .disconnected)
        #expect(await stateIterator.next() == nil)

        var levelIterator = levels.makeAsyncIterator()
        #expect(await levelIterator.next() == nil)
    }

    @Test func connectionStatesMulticastsToMultipleSubscribers() async throws {
        let (source, transport) = makeSource()
        let states1 = await source.connectionStates()
        let states2 = await source.connectionStates()
        _ = try await source.start()
        var iterator1 = states1.makeAsyncIterator()
        var iterator2 = states2.makeAsyncIterator()

        await transport.emit(.connecting)
        #expect(await iterator1.next() == .connecting)
        #expect(await iterator2.next() == .connecting)
        await source.stop()
    }

    @Test func reconnectResetsAssemblerSoNoPhantomGap() async throws {
        let (source, transport) = makeSource()
        let stream = try await source.start()
        await transport.emit(.connected(codecValue: OmiConstants.codecPCM16at16kHz))
        await feedSamples(transport, from: 100, count: 4096)
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next()
        await transport.emit(.disconnected)
        // Reconnect: firmware restarts its counter — must NOT be treated as a huge gap.
        await transport.emit(.connected(codecValue: OmiConstants.codecPCM16at16kHz))
        await feedSamples(transport, from: 0, count: 4096)
        let chunk = await iterator.next()
        // A phantom gap would inject 320×N zeros; all samples must be the 0x0100 value.
        #expect(chunk?.samples.allSatisfy { abs($0 - Float(0x0100) / 32_768.0) < 0.0001 } == true)
        await source.stop()
    }
}

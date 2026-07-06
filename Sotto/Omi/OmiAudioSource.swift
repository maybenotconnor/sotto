import Foundation

/// AudioSource over an OmiTransport: raw BLE notifications → frames → floats → 4096-sample
/// AudioChunks. Connection lifecycle (reconnect) lives in the TRANSPORT; failover timing
/// lives in FailoverAudioSource. This actor is a decode pipeline plus state relay.
actor OmiAudioSource: ConnectableAudioSource {
    nonisolated let sourceType: AudioSourceType = .omi
    nonisolated var isAvailable: Bool { true }

    enum OmiSourceError: Error { case alreadyStarted }

    private let transport: any OmiTransport
    private let deviceID: UUID

    private var continuation: AsyncStream<AudioChunk>.Continuation?
    private var eventTask: Task<Void, Never>?
    private var assembler = OmiFrameAssembler()
    private var decoder: OmiAudioDecoder?
    private var chunker = SampleChunker()
    private var hasStreamedSinceConnect = false

    private var stateContinuations: [UUID: AsyncStream<OmiConnectionState>.Continuation] = [:]
    private var batteryContinuations: [UUID: AsyncStream<Int>.Continuation] = [:]
    private(set) var latestBatteryLevel: Int?
    private(set) var setupFailureMessage: String?

    init(transport: any OmiTransport, deviceID: UUID) {
        self.transport = transport
        self.deviceID = deviceID
    }

    func start() async throws -> AsyncStream<AudioChunk> {
        guard eventTask == nil else { throw OmiSourceError.alreadyStarted }
        let (stream, continuation) = AsyncStream.makeStream(of: AudioChunk.self)
        self.continuation = continuation
        let events = await transport.events(deviceID: deviceID)
        eventTask = Task { [weak self] in
            for await event in events {
                await self?.handle(event)
            }
        }
        return stream
    }

    func stop() async {
        // Order matters for quiescence: finish the transport stream first, THEN drain the
        // pump to completion so any buffered straggler events run through handle() BEFORE
        // the resets below. (Task.cancel() is inert on a plain for-await over AsyncStream —
        // only finish() ends it.) No deadlock: while stop() suspends awaiting eventTask,
        // the actor is free to run handle().
        await transport.stopEvents()
        await eventTask?.value
        eventTask = nil
        continuation?.finish()
        continuation = nil
        assembler.reset()
        chunker.reset()
        decoder = nil
        hasStreamedSinceConnect = false
        setupFailureMessage = nil
        // Terminate observer streams so downstream consumers (FailoverAudioSource,
        // AppModel) don't hang on a stream that will never yield again. Subscribers that
        // survive a restart re-subscribe after start().
        yieldState(.disconnected)
        for continuation in stateContinuations.values { continuation.finish() }
        stateContinuations.removeAll()
        for continuation in batteryContinuations.values { continuation.finish() }
        batteryContinuations.removeAll()
    }

    func connectionStates() -> AsyncStream<OmiConnectionState> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: OmiConnectionState.self)
        stateContinuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeStateContinuation(id) }
        }
        return stream
    }

    func batteryLevels() -> AsyncStream<Int> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: Int.self)
        batteryContinuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeBatteryContinuation(id) }
        }
        return stream
    }

    private func removeStateContinuation(_ id: UUID) { stateContinuations[id] = nil }
    private func removeBatteryContinuation(_ id: UUID) { batteryContinuations[id] = nil }

    private func yieldState(_ state: OmiConnectionState) {
        for continuation in stateContinuations.values { continuation.yield(state) }
    }

    private func handle(_ event: OmiTransportEvent) {
        switch event {
        case .connecting:
            yieldState(.connecting)
        case .connected(let codecValue):
            // Fresh session: firmware restarts its packet counter; stale fragments and
            // chunker remainders belong to the previous connection.
            assembler.reset()
            chunker.reset()
            hasStreamedSinceConnect = false
            do {
                decoder = try OmiAudioDecoder(codecValue: codecValue)
                setupFailureMessage = nil
            } catch {
                decoder = nil
                setupFailureMessage = "Omi firmware uses an unsupported audio codec (value \(codecValue))."
            }
            yieldState(.connected)
        case .audioNotification(let data):
            guard let decoder else { return }
            if !hasStreamedSinceConnect {
                hasStreamedSinceConnect = true
                yieldState(.streaming)
            }
            for output in assembler.ingest(data) {
                let samples = decoder.decode(output)
                guard !samples.isEmpty else { continue }
                for chunk in chunker.append(samples: samples, hostTime: mach_absolute_time()) {
                    continuation?.yield(chunk)
                }
            }
        case .batteryLevel(let percent):
            latestBatteryLevel = percent
            for continuation in batteryContinuations.values { continuation.yield(percent) }
        case .disconnected:
            hasStreamedSinceConnect = false
            yieldState(.disconnected)
        case .bluetoothUnavailable(let reason):
            hasStreamedSinceConnect = false
            yieldState(.unavailable(reason))
        }
    }
}

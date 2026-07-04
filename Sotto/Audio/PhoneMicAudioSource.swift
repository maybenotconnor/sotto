import AVFoundation
import Synchronization

/// MVP audio source: built-in phone mic via AVAudioEngine.
///
/// Everything tap-related lives in this one file on purpose — `installTap` is slated for
/// deprecation (iOS 27 renames it `installAudioTap`), so migration stays a one-file change.
actor PhoneMicAudioSource: AudioSource {
    nonisolated let sourceType: AudioSourceType = .phoneMic
    nonisolated var isAvailable: Bool { true }

    enum AudioSourceError: Error {
        case microphonePermissionDenied
        case converterUnavailable
        case invalidHardwareFormat
        case alreadyStarted
    }

    private var engine: AVAudioEngine?
    private var continuation: AsyncStream<AudioChunk>.Continuation?

    func start() async throws -> AsyncStream<AudioChunk> {
        guard engine == nil else { throw AudioSourceError.alreadyStarted }
        guard await AVAudioApplication.requestRecordPermission() else {
            throw AudioSourceError.microphonePermissionDenied
        }
        try Self.configureSession()

        let engine = AVAudioEngine()
        let input = engine.inputNode
        // Tap at the HARDWARE format — requesting 16 kHz here crashes with a format mismatch.
        let hardwareFormat = input.outputFormat(forBus: 0)
        // installTap traps (Obj-C precondition) on a 0 Hz/0-channel format — reject the
        // documented no-valid-input-route degenerate state with a recoverable throw instead.
        guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0 else {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            throw AudioSourceError.invalidHardwareFormat
        }
        guard let converter = FormatConverter(inputFormat: hardwareFormat) else {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            throw AudioSourceError.converterUnavailable
        }

        let processor = TapProcessor(converter: converter)
        // Unbounded buffering is deliberate: a render tap can't take backpressure, and dropping
        // chunks would lose audio. A stalled consumer grows ~256 KB/min — acceptable, visible.
        let (stream, continuation) = AsyncStream.makeStream(of: AudioChunk.self)

        input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(VADConstants.chunkSize), format: hardwareFormat) { buffer, when in
            processor.handle(buffer, hostTime: when.hostTime, continuation: continuation)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            continuation.finish()
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            throw error
        }

        self.engine = engine
        self.continuation = continuation
        return stream
    }

    func stop() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        continuation?.finish()
        continuation = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Route change (.oldDeviceUnavailable): the hardware format may have changed (SPEC —
    /// e.g. wired mic unplugged). Rebuild converter + tap on the SAME stream; engine keeps
    /// running. No-op when not capturing.
    func rebuildTap() throws {
        guard let engine, let continuation else { return }
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        let hardwareFormat = input.outputFormat(forBus: 0)
        guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0,
              let converter = FormatConverter(inputFormat: hardwareFormat) else {
            throw AudioSourceError.invalidHardwareFormat
        }
        let processor = TapProcessor(converter: converter)
        input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(VADConstants.chunkSize),
                         format: hardwareFormat) { buffer, when in
            processor.handle(buffer, hostTime: when.hostTime, continuation: continuation)
        }
    }

    /// `.playAndRecord` + `.mixWithOthers` so activating the session never pauses the
    /// user's music. No Bluetooth input options: AirPods stay on A2DP output while the
    /// phone mic records (see SPEC "PhoneMicAudioSource").
    static func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers])
        try session.setActive(true)
    }
}

/// Runs inside the audio tap callback: convert to 16 kHz mono, copy samples out
/// synchronously, chunk, and yield. `Mutex` (not an actor) because the tap thread
/// must never await.
private final class TapProcessor: Sendable {
    private struct State {
        var converter: FormatConverter
        var chunker = SampleChunker()
    }

    private let state: Mutex<State>

    init(converter: FormatConverter) {
        self.state = Mutex(State(converter: converter))
    }

    func handle(
        _ buffer: AVAudioPCMBuffer,
        hostTime: UInt64,
        continuation: AsyncStream<AudioChunk>.Continuation
    ) {
        let chunks = state.withLock { state -> [AudioChunk] in
            let samples = state.converter.convert(buffer)
            return state.chunker.append(samples: samples, hostTime: hostTime)
        }
        for chunk in chunks {
            continuation.yield(chunk)
        }
    }
}

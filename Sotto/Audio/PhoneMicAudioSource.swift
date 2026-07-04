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
    }

    private var engine: AVAudioEngine?
    private var continuation: AsyncStream<AudioChunk>.Continuation?

    func start() async throws -> AsyncStream<AudioChunk> {
        guard await AVAudioApplication.requestRecordPermission() else {
            throw AudioSourceError.microphonePermissionDenied
        }
        try Self.configureSession()

        let engine = AVAudioEngine()
        let input = engine.inputNode
        // Tap at the HARDWARE format — requesting 16 kHz here crashes with a format mismatch.
        let hardwareFormat = input.outputFormat(forBus: 0)
        guard let converter = FormatConverter(inputFormat: hardwareFormat) else {
            throw AudioSourceError.converterUnavailable
        }

        let processor = TapProcessor(converter: converter)
        let (stream, continuation) = AsyncStream.makeStream(of: AudioChunk.self)

        input.installTap(onBus: 0, bufferSize: 4096, format: hardwareFormat) { buffer, when in
            processor.handle(buffer, hostTime: when.hostTime, continuation: continuation)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            continuation.finish()
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

    /// `.playAndRecord` + `.mixWithOthers` so activating the session never pauses the
    /// user's music. No Bluetooth input options: AirPods stay on A2DP output while the
    /// phone mic records (see SPEC "PhoneMicAudioSource").
    static func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers])
        try session.setActive(true)
    }
}

// `FormatConverter` is only ever touched from within `TapProcessor.state`'s `Mutex` lock,
// which serializes access — so it's genuinely thread-safe despite not being Sendable itself
// (it wraps a non-Sendable `AVAudioConverter`). Needed because a non-Sendable stored property
// otherwise defeats region-isolation checking of the `Mutex<State>`-protected access below.
extension FormatConverter: @unchecked Sendable {}

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

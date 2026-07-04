import CoreML
import FluidAudio
import Foundation

/// Single source of truth for the pipeline's chunk geometry — Silero's fixed model input
/// (4096 samples = 256 ms @ 16 kHz). Everything upstream (chunker default, tap buffer
/// size, test fakes) must reference this, never a literal.
enum VADConstants {
    static let chunkSize = VadManager.chunkSize
    static let sampleRate = VadManager.sampleRate
}

/// Silero VAD v6 via FluidAudio, with the CoreML model loaded from the app bundle —
/// FluidAudio's HuggingFace download path is deliberately never exercised.
actor SileroSpeechDetector: SpeechDetecting {
    static let modelResourceName = "silero-vad-unified-256ms-v6.0.0"

    private let vad: VadManager
    private var streamState: VadStreamState

    init(modelURL: URL, threshold: Float = 0.6) throws {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        let model = try MLModel(contentsOf: modelURL, configuration: configuration)
        self.vad = VadManager(config: VadConfig(defaultThreshold: threshold), vadModel: model)
        self.streamState = VadStreamState.initial()
    }

    func process(_ chunk: AudioChunk) async throws -> SpeechEvent? {
        let result: VadStreamResult
        do {
            result = try await vad.processStreamingChunk(
                chunk.samples,
                state: streamState,
                config: .default,
                returnSeconds: true,
                timeResolution: 2)
        } catch {
            // Keep time bookkeeping monotonic even when inference fails: event timestamps
            // derive from processedSamples, so a skipped chunk would silently shift every
            // later speechStart/speechEnd 256 ms early for the rest of the session.
            streamState.processedSamples += chunk.samples.count
            throw error
        }
        streamState = result.state
        guard let event = result.event else { return nil }
        switch event.kind {
        case .speechStart: return .speechStart(time: event.time)
        case .speechEnd: return .speechEnd(time: event.time)
        }
    }

    /// Test hook: total samples the streaming state has accounted for.
    func processedSampleCount() -> Int {
        streamState.processedSamples
    }

    func reset() {
        streamState = VadStreamState.initial()
    }
}

import CoreML
import FluidAudio
import Foundation

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
        let result = try await vad.processStreamingChunk(
            chunk.samples,
            state: streamState,
            config: .default,
            returnSeconds: true,
            timeResolution: 2)
        streamState = result.state
        guard let event = result.event else { return nil }
        switch event.kind {
        case .speechStart: return .speechStart(time: event.time)
        case .speechEnd: return .speechEnd(time: event.time)
        }
    }

    func reset() {
        streamState = VadStreamState.initial()
    }
}

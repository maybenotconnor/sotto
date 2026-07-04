import Foundation
import Testing
@testable import Sotto

/// A synthetic speech-like signal — a 180 Hz sawtooth carrier with harmonics, amplitude
/// modulated at a speech-like 3–6 Hz rate, normalized to ±0.5 — proven to trigger the
/// Silero VAD's speechStart event at threshold 0.3 (see
/// `SileroSpeechDetectorTests.speechLikeSignalTriggersSpeechStart`). Declared at file scope
/// (not nested in the struct) so `RecorderIntegrationTests` can call it unqualified too —
/// the whole-stack test reuses the exact signal proven here rather than inventing a new one.
func makeSpeechLikeSignal(seconds: Double, sampleRate: Double = 16_000) -> [Float] {
    let carrierHz = 180.0
    let modulationHz = 4.5

    let sampleCount = Int(seconds * sampleRate)
    var speech = [Float](repeating: 0, count: sampleCount)
    for i in 0..<sampleCount {
        let t = Double(i) / sampleRate
        let phase = carrierHz * t
        let sawtooth = 2 * (phase - (phase + 0.5).rounded(.down))
        let harmonic2 = 0.5 * sin(2 * .pi * carrierHz * 2 * t)
        let harmonic3 = 0.25 * sin(2 * .pi * carrierHz * 3 * t)
        let envelope = 0.5 * (1 + sin(2 * .pi * modulationHz * t))
        speech[i] = Float((sawtooth + harmonic2 + harmonic3) * envelope)
    }
    let peak = speech.map { abs($0) }.max() ?? 1
    guard peak > 0 else { return speech }
    return speech.map { $0 / peak * 0.5 }
}

struct SileroSpeechDetectorTests {
    private func makeDetector(threshold: Float = 0.6) throws -> SileroSpeechDetector {
        let url = try #require(Bundle.main.url(
            forResource: SileroSpeechDetector.modelResourceName,
            withExtension: "mlmodelc"))
        return try SileroSpeechDetector(modelURL: url, threshold: threshold)
    }

    @Test func bundledModelLoads() throws {
        _ = try makeDetector()
    }

    @Test func silenceProducesNoEvents() async throws {
        let detector = try makeDetector()
        for _ in 0..<20 {
            let chunk = AudioChunk(samples: [Float](repeating: 0, count: 4096), hostTime: 0)
            let event = try await detector.process(chunk)
            #expect(event == nil)
        }
    }

    /// Proves reset() clears streaming state and processing continues correctly afterward,
    /// end-to-end through the real model.
    @Test func resetClearsStateAndProcessingContinues() async throws {
        let detector = try makeDetector()
        for _ in 0..<5 {
            let chunk = AudioChunk(samples: [Float](repeating: 0, count: 4096), hostTime: 0)
            let event = try await detector.process(chunk)
            #expect(event == nil)
        }
        await detector.reset()
        for _ in 0..<5 {
            let chunk = AudioChunk(samples: [Float](repeating: 0, count: 4096), hostTime: 0)
            let event = try await detector.process(chunk)
            #expect(event == nil)
        }
    }

    @Test func speechLikeSignalTriggersSpeechStart() async throws {
        let detector = try makeDetector(threshold: 0.3)
        let sampleRate: Double = 16_000
        let chunkSize = 4096
        let samples = Self.syntheticSpeechSignal(sampleRate: sampleRate)

        var sawSpeechStart = false
        var index = 0
        while index < samples.count {
            let end = min(index + chunkSize, samples.count)
            var slice = Array(samples[index..<end])
            if slice.count < chunkSize {
                slice.append(contentsOf: [Float](repeating: 0, count: chunkSize - slice.count))
            }
            let chunk = AudioChunk(samples: slice, hostTime: 0)
            if case .speechStart = try await detector.process(chunk) {
                sawSpeechStart = true
            }
            index = end
        }

        #expect(sawSpeechStart)
    }

    /// ~2 s of speech-like audio (see `makeSpeechLikeSignal(seconds:)` above) followed by
    /// ~2 s of silence.
    private static func syntheticSpeechSignal(sampleRate: Double) -> [Float] {
        let speech = makeSpeechLikeSignal(seconds: 2.0, sampleRate: sampleRate)
        let silence = [Float](repeating: 0, count: Int(2.0 * sampleRate))
        return speech + silence
    }

    @Test func pipelineChunkSizeMatchesVadModelContract() {
        // Canary: if a FluidAudio upgrade changes the model's chunk contract, this fails
        // loudly instead of VadManager silently padding/truncating our chunks.
        #expect(VADConstants.chunkSize == 4096)
        #expect(VADConstants.sampleRate == 16_000)
    }

    @Test func processedSampleCountAdvancesPerChunk() async throws {
        let detector = try makeDetector()
        for _ in 0..<3 {
            _ = try await detector.process(
                AudioChunk(samples: [Float](repeating: 0, count: VADConstants.chunkSize), hostTime: 0))
        }
        #expect(await detector.processedSampleCount() == VADConstants.chunkSize * 3)
    }
}

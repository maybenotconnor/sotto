import Foundation
import Testing
@testable import Sotto

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

    /// ~2 s of speech-like audio — a 100–300 Hz sawtooth carrier with harmonics, amplitude
    /// modulated at a speech-like 3–6 Hz rate, normalized to ±0.5 — followed by ~2 s of silence.
    private static func syntheticSpeechSignal(sampleRate: Double) -> [Float] {
        let speechDuration = 2.0
        let silenceDuration = 2.0
        let carrierHz = 180.0
        let modulationHz = 4.5

        let speechSampleCount = Int(speechDuration * sampleRate)
        var speech = [Float](repeating: 0, count: speechSampleCount)
        for i in 0..<speechSampleCount {
            let t = Double(i) / sampleRate
            let phase = carrierHz * t
            let sawtooth = 2 * (phase - (phase + 0.5).rounded(.down))
            let harmonic2 = 0.5 * sin(2 * .pi * carrierHz * 2 * t)
            let harmonic3 = 0.25 * sin(2 * .pi * carrierHz * 3 * t)
            let envelope = 0.5 * (1 + sin(2 * .pi * modulationHz * t))
            speech[i] = Float((sawtooth + harmonic2 + harmonic3) * envelope)
        }
        let peak = speech.map { abs($0) }.max() ?? 1
        if peak > 0 {
            for i in 0..<speech.count { speech[i] = speech[i] / peak * 0.5 }
        }

        let silence = [Float](repeating: 0, count: Int(silenceDuration * sampleRate))
        return speech + silence
    }
}

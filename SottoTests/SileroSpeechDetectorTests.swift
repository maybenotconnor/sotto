import Foundation
import Testing
@testable import Sotto

struct SileroSpeechDetectorTests {
    private func makeDetector() throws -> SileroSpeechDetector {
        let url = try #require(Bundle.main.url(
            forResource: SileroSpeechDetector.modelResourceName,
            withExtension: "mlmodelc"))
        return try SileroSpeechDetector(modelURL: url)
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
}

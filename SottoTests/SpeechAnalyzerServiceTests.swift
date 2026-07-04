import AVFoundation
import Foundation
import Testing
@testable import Sotto

struct SpeechAnalyzerServiceTests {
    @Test func throwsUnavailableRatherThanPromptingWhenAssetsMissing() async throws {
        // On simulators without Apple Intelligence assets this exercises the guard path;
        // on machines WITH assets installed it exercises real transcription instead.
        let service = SpeechAnalyzerService(locale: Locale(identifier: "en_US"))
        guard await SpeechAnalyzerService.assetsInstalled(for: Locale(identifier: "en_US")) else {
            await #expect(throws: TranscriptionError.self) {
                _ = try await service.transcribe(
                    file: URL(fileURLWithPath: "/nonexistent.m4a"))
            }
            return
        }
        // Assets installed: transcribe 1 s of synthetic tone — must complete without
        // throwing and produce a (possibly empty) result. Real-speech accuracy is a
        // device/manual concern, not a unit gate.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SATests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let caf = dir.appendingPathComponent("t.caf"); let m4a = dir.appendingPathComponent("t.m4a")
        let writer = try CAFSegmentWriter(cafURL: caf, m4aURL: m4a)
        try writer.append((0..<VADConstants.sampleRate).map {
            sinf(2 * .pi * 300 * Float($0) / Float(VADConstants.sampleRate)) * 0.3
        })
        writer.close()
        try CAFSegmentWriter.transcodeToM4A(caf: caf, m4a: m4a)
        let result = try await service.transcribe(file: m4a)
        #expect(result.backend == .speechAnalyzer)
        #expect(result.duration > 0.5)
    }
}

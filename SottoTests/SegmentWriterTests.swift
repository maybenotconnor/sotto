import AVFoundation
import Foundation
import Testing
@testable import Sotto

struct SegmentWriterTests {
    private func tempURLs() -> (caf: URL, m4a: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SegmentWriterTests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (dir.appendingPathComponent("seg.caf"), dir.appendingPathComponent("seg.m4a"))
    }

    private func sineChunk(seconds: Double) -> [Float] {
        let count = Int(seconds * Double(VADConstants.sampleRate))
        return (0..<count).map { sinf(2 * .pi * 440 * Float($0) / Float(VADConstants.sampleRate)) * 0.5 }
    }

    @Test func writesCAFWhileAppendingWithoutFinalize() throws {
        let (caf, m4a) = tempURLs()
        let writer = try CAFSegmentWriter(cafURL: caf, m4aURL: m4a)
        try writer.append(sineChunk(seconds: 0.5))
        #expect(writer.writtenSampleCount == VADConstants.sampleRate / 2)
        #expect(FileManager.default.fileExists(atPath: caf.path))
        #expect(!FileManager.default.fileExists(atPath: m4a.path))
    }

    @Test func finalizeProducesReadableM4AAndDeletesCAF() throws {
        let (caf, m4a) = tempURLs()
        let writer = try CAFSegmentWriter(cafURL: caf, m4aURL: m4a)
        try writer.append(sineChunk(seconds: 1.0))
        let url = try writer.finalize()
        #expect(url == m4a)
        #expect(!FileManager.default.fileExists(atPath: caf.path))
        let file = try AVAudioFile(forReading: m4a)
        let duration = Double(file.length) / file.processingFormat.sampleRate
        #expect(abs(duration - 1.0) < 0.15)   // AAC priming/padding tolerance
    }

    @Test func discardRemovesEverything() throws {
        let (caf, m4a) = tempURLs()
        let writer = try CAFSegmentWriter(cafURL: caf, m4aURL: m4a)
        try writer.append(sineChunk(seconds: 0.3))
        writer.discard()
        #expect(!FileManager.default.fileExists(atPath: caf.path))
        #expect(!FileManager.default.fileExists(atPath: m4a.path))
    }

    @Test func unfinalizedCAFIsSalvageableByTranscode() throws {
        let (caf, m4a) = tempURLs()
        do {
            let writer = try CAFSegmentWriter(cafURL: caf, m4aURL: m4a)
            try writer.append(sineChunk(seconds: 0.8))
            // Simulate a crash: writer dropped without finalize() or discard().
        }
        try CAFSegmentWriter.transcodeToM4A(caf: caf, m4a: m4a)
        let file = try AVAudioFile(forReading: m4a)
        let duration = Double(file.length) / file.processingFormat.sampleRate
        #expect(abs(duration - 0.8) < 0.15)
    }
}

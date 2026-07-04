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

    @Test func closeKeepsCAFOnDiskAndDeferredTranscodeProducesM4A() throws {
        let (caf, m4a) = tempURLs()
        let writer = try CAFSegmentWriter(cafURL: caf, m4aURL: m4a)
        try writer.append(sineChunk(seconds: 1.0))
        writer.close()
        #expect(FileManager.default.fileExists(atPath: caf.path))     // close is NOT transcode
        #expect(!FileManager.default.fileExists(atPath: m4a.path))
        try CAFSegmentWriter.transcodeToM4A(caf: caf, m4a: m4a)       // the queue's job
        let file = try AVAudioFile(forReading: m4a)
        #expect(abs(Double(file.length) / file.processingFormat.sampleRate - 1.0) < 0.15)
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
            // Simulate a crash: writer dropped without finalize() or discard(). This proves
            // recovery from a writer released without finalize (ARC dealloc flushes); it does
            // not simulate a true process kill (jetsam/power loss). For that case, CAF's
            // self-describing format plus already-flushed writes are the design basis.
        }
        try CAFSegmentWriter.transcodeToM4A(caf: caf, m4a: m4a)
        let file = try AVAudioFile(forReading: m4a)
        let duration = Double(file.length) / file.processingFormat.sampleRate
        #expect(abs(duration - 0.8) < 0.15)
    }
}

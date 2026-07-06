import AVFoundation
import Foundation
import Testing
@testable import Sotto

struct AudioStitcherTests {
    /// Real .m4a fixture the same way testDeepgramKey fabricates one: CAF write → transcode.
    private func makeM4A(seconds: Double, in dir: URL, name: String) throws -> URL {
        let cafURL = dir.appendingPathComponent("\(name).caf")
        let m4aURL = dir.appendingPathComponent("\(name).m4a")
        let writer = try CAFSegmentWriter(cafURL: cafURL, m4aURL: m4aURL)
        try writer.append([Float](repeating: 0, count: Int(seconds * Double(VADConstants.sampleRate))))
        writer.close()
        try CAFSegmentWriter.transcodeToM4A(caf: cafURL, m4a: m4aURL)
        try FileManager.default.removeItem(at: cafURL)
        return m4aURL
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("StitcherTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func stitchedDurationIsSumOfParts() async throws {
        let dir = try tempDir()
        let a = try makeM4A(seconds: 0.5, in: dir, name: "a")
        let b = try makeM4A(seconds: 0.75, in: dir, name: "b")
        let output = dir.appendingPathComponent("out.m4a")

        try await AudioStitcher.stitch(parts: [a, b], to: output)

        #expect(FileManager.default.fileExists(atPath: output.path))
        let duration = try await AVURLAsset(url: output).load(.duration).seconds
        #expect(abs(duration - 1.25) < 0.2)   // AAC priming/frame padding tolerance
    }

    @Test func unreadablePartThrows() async throws {
        let dir = try tempDir()
        let good = try makeM4A(seconds: 0.5, in: dir, name: "good")
        let garbage = dir.appendingPathComponent("garbage.m4a")
        try Data([0x00, 0x01]).write(to: garbage)
        let output = dir.appendingPathComponent("out.m4a")

        await #expect(throws: (any Error).self) {
            try await AudioStitcher.stitch(parts: [good, garbage], to: output)
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }
}

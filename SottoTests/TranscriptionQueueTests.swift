import AVFoundation
import Foundation
import Testing
@testable import Sotto

struct TranscriptionQueueTests {
    private func makeSegment(in dir: URL, speech: Bool = true) throws -> FinalizedSegment {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let caf = dir.appendingPathComponent("seg.caf")
        let m4a = dir.appendingPathComponent("seg.m4a")
        let writer = try CAFSegmentWriter(cafURL: caf, m4aURL: m4a)
        let samples = (0..<VADConstants.sampleRate).map {
            sinf(2 * .pi * 300 * Float($0) / Float(VADConstants.sampleRate)) * 0.4
        }
        try writer.append(samples)
        writer.close()
        return FinalizedSegment(
            cafURL: caf, m4aURL: m4a, startDate: Date(), duration: 1.0, speechDuration: 1.0)
    }

    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("QueueTests-\(UUID().uuidString)")
    }

    @Test func drainTranscodesTranscribesWritesMarkdownAndDeletesCAF() async throws {
        let dir = tempDir()
        let segment = try makeSegment(in: dir)
        let service = FakeTranscriptionService(text: "hello world")
        let queue = TranscriptionQueue(
            storeURL: dir.appendingPathComponent("jobs.json"), service: service)

        await queue.enqueue(segment)
        await queue.drain()

        #expect(!FileManager.default.fileExists(atPath: segment.cafURL.path))
        #expect(FileManager.default.fileExists(atPath: segment.m4aURL.path))
        let md = dir.appendingPathComponent("seg.md")
        #expect(try String(contentsOf: md, encoding: .utf8).contains("hello world"))
        #expect(await queue.jobs.first?.state == .done)
        #expect(await service.calls == 1)
    }

    @Test func jobsPersistAcrossQueueInstances() async throws {
        let dir = tempDir()
        let segment = try makeSegment(in: dir)
        let store = dir.appendingPathComponent("jobs.json")
        let failing = FakeTranscriptionService(text: "x", failuresBeforeSuccess: .max)
        let first = TranscriptionQueue(storeURL: store, service: failing, maxAttempts: 1)
        await first.enqueue(segment)
        await first.drain()
        #expect(await first.jobs.first?.state == .failed)

        // A fresh instance (new launch) reloads the same jobs file:
        let second = TranscriptionQueue(storeURL: store, service: FakeTranscriptionService(text: "y"))
        #expect(await second.jobs.count == 1)
        #expect(await second.jobs.first?.state == .failed)
    }

    @Test func retriesThenSucceeds() async throws {
        let dir = tempDir()
        let segment = try makeSegment(in: dir)
        let service = FakeTranscriptionService(text: "eventually", failuresBeforeSuccess: 2)
        let queue = TranscriptionQueue(
            storeURL: dir.appendingPathComponent("jobs.json"), service: service, maxAttempts: 5)
        await queue.enqueue(segment)
        await queue.drain()   // attempt 1 fails (still pending, attempts=1)
        await queue.drain()   // attempt 2 fails
        await queue.drain()   // attempt 3 succeeds
        #expect(await queue.jobs.first?.state == .done)
    }

    @Test func salvagedCAFIsToleratedWhenM4AAlreadyExists() async throws {
        let dir = tempDir()
        let segment = try makeSegment(in: dir)
        // Simulate the launch salvage sweep having already transcoded + deleted the CAF:
        try CAFSegmentWriter.transcodeToM4A(caf: segment.cafURL, m4a: segment.m4aURL)
        try FileManager.default.removeItem(at: segment.cafURL)

        let queue = TranscriptionQueue(
            storeURL: dir.appendingPathComponent("jobs.json"),
            service: FakeTranscriptionService(text: "salvaged"))
        await queue.enqueue(segment)
        await queue.drain()
        #expect(await queue.jobs.first?.state == .done)
    }

    @Test func bothFilesMissingMarksFailedWithoutThrowing() async throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ghost = FinalizedSegment(
            cafURL: dir.appendingPathComponent("ghost.caf"),
            m4aURL: dir.appendingPathComponent("ghost.m4a"),
            startDate: Date(), duration: 1, speechDuration: 1)
        let queue = TranscriptionQueue(
            storeURL: dir.appendingPathComponent("jobs.json"),
            service: FakeTranscriptionService(text: "x"))
        await queue.enqueue(ghost)
        await queue.drain()
        #expect(await queue.jobs.first?.state == .failed)
    }
}

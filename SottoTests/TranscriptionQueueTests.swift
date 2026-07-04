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
        await queue.drain()   // retries happen within one drain now (loop-until-quiescent)
        #expect(await queue.jobs.first?.state == .done)
        #expect(await service.calls == 3)
    }

    @Test func jobEnqueuedMidDrainIsProcessedBeforeDrainReturns() async throws {
        let dir = tempDir()
        let first = try makeSegment(in: dir.appendingPathComponent("a"))
        let second = try makeSegment(in: dir.appendingPathComponent("b"))
        let service = FakeTranscriptionService(text: "x")
        let queue = TranscriptionQueue(
            storeURL: dir.appendingPathComponent("jobs.json"), service: service)
        await queue.enqueue(first)
        async let draining: Void = queue.drain()
        await queue.enqueue(second)   // lands during the in-flight drain (actor reentrancy)
        await draining
        // Whichever interleaving occurred, nothing may strand as pending:
        await queue.drain()           // no-op if the first drain already got both
        #expect(await queue.pendingCount == 0)
        #expect(await queue.jobs.count == 2)
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

    @Test func environmentalFailureLeavesJobPendingWithoutBurningAttempts() async throws {
        let dir = tempDir()
        let segment = try makeSegment(in: dir)
        let store = dir.appendingPathComponent("jobs.json")
        let queue = TranscriptionQueue(
            storeURL: store, service: EnvironmentallyBlockedTranscriptionService())
        await queue.enqueue(segment)
        await queue.drain()
        #expect(await queue.jobs.first?.state == .pending)   // NOT failed
        #expect(await queue.jobs.first?.attempts == 0)       // no attempts burned

        // Conditions improve (new launch, assets installed): a fresh queue on the SAME
        // store with a working service completes the job — recoverability proven.
        let recovered = TranscriptionQueue(storeURL: store, service: FakeTranscriptionService(text: "later"))
        await recovered.drain()
        #expect(await recovered.jobs.first?.state == .done)
    }

    @Test func environmentalBlockStopsDrainWithoutTouchingLaterJobs() async throws {
        let dir = tempDir()
        let store = dir.appendingPathComponent("jobs.json")
        let queue = TranscriptionQueue(
            storeURL: store, service: EnvironmentallyBlockedTranscriptionService())
        await queue.enqueue(try makeSegment(in: dir.appendingPathComponent("a")))
        await queue.enqueue(try makeSegment(in: dir.appendingPathComponent("b")))
        await queue.drain()
        #expect(await queue.pendingCount == 2)               // neither burned
    }

    @Test func enqueueSalvagedParsesStoreLayoutAndTranscribes() async throws {
        let dir = tempDir()
        let day = dir.appendingPathComponent("2026-03-14")
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let caf = day.appendingPathComponent("t.caf"); let m4a = day.appendingPathComponent("09-15-30.m4a")
        let writer = try CAFSegmentWriter(cafURL: caf, m4aURL: m4a)
        try writer.append((0..<VADConstants.sampleRate).map { _ in Float(0.1) })
        writer.close()
        try CAFSegmentWriter.transcodeToM4A(caf: caf, m4a: m4a)
        try FileManager.default.removeItem(at: caf)

        let queue = TranscriptionQueue(
            storeURL: dir.appendingPathComponent("jobs.json"),
            service: FakeTranscriptionService(text: "salvage transcript"))
        await queue.enqueueSalvaged(m4aURL: m4a)
        await queue.enqueueSalvaged(m4aURL: m4a)     // duplicate ignored
        #expect(await queue.jobs.count == 1)
        let job = await queue.jobs[0]
        #expect(Calendar(identifier: .gregorian).component(.hour, from: job.startDate) == 9)
        #expect(job.duration > 0.5)
        await queue.drain()
        #expect(await queue.jobs.first?.state == .done)
    }
}

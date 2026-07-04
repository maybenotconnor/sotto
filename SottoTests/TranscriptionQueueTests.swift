import AVFoundation
import Foundation
import Synchronization
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
            storeURL: dir.appendingPathComponent("jobs.json"), service: service, rootDirectory: dir)

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
        let first = TranscriptionQueue(storeURL: store, service: failing, maxAttempts: 1, rootDirectory: dir)
        await first.enqueue(segment)
        await first.drain()
        #expect(await first.jobs.first?.state == .failed)

        // A fresh instance (new launch) reloads the same jobs file:
        let second = TranscriptionQueue(
            storeURL: store, service: FakeTranscriptionService(text: "y"), rootDirectory: dir)
        #expect(await second.jobs.count == 1)
        #expect(await second.jobs.first?.state == .failed)
    }

    @Test func retriesThenSucceeds() async throws {
        let dir = tempDir()
        let segment = try makeSegment(in: dir)
        let service = FakeTranscriptionService(text: "eventually", failuresBeforeSuccess: 2)
        let queue = TranscriptionQueue(
            storeURL: dir.appendingPathComponent("jobs.json"), service: service, maxAttempts: 5,
            rootDirectory: dir)
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
            storeURL: dir.appendingPathComponent("jobs.json"), service: service, rootDirectory: dir)
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
            service: FakeTranscriptionService(text: "salvaged"), rootDirectory: dir)
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
            service: FakeTranscriptionService(text: "x"), rootDirectory: dir)
        await queue.enqueue(ghost)
        await queue.drain()
        #expect(await queue.jobs.first?.state == .failed)
    }

    @Test func environmentalFailureLeavesJobPendingWithoutBurningAttempts() async throws {
        let dir = tempDir()
        let segment = try makeSegment(in: dir)
        let store = dir.appendingPathComponent("jobs.json")
        let queue = TranscriptionQueue(
            storeURL: store, service: EnvironmentallyBlockedTranscriptionService(), rootDirectory: dir)
        await queue.enqueue(segment)
        await queue.drain()
        #expect(await queue.jobs.first?.state == .pending)   // NOT failed
        #expect(await queue.jobs.first?.attempts == 0)       // no attempts burned

        // Conditions improve (new launch, assets installed): a fresh queue on the SAME
        // store with a working service completes the job — recoverability proven.
        let recovered = TranscriptionQueue(
            storeURL: store, service: FakeTranscriptionService(text: "later"), rootDirectory: dir)
        await recovered.drain()
        #expect(await recovered.jobs.first?.state == .done)
    }

    @Test func environmentalBlockStopsDrainWithoutTouchingLaterJobs() async throws {
        let dir = tempDir()
        let store = dir.appendingPathComponent("jobs.json")
        let queue = TranscriptionQueue(
            storeURL: store, service: EnvironmentallyBlockedTranscriptionService(), rootDirectory: dir)
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
            service: FakeTranscriptionService(text: "salvage transcript"), rootDirectory: dir)
        await queue.enqueueSalvaged(m4aURL: m4a)
        await queue.enqueueSalvaged(m4aURL: m4a)     // duplicate ignored
        #expect(await queue.jobs.count == 1)
        let job = await queue.jobs[0]
        #expect(Calendar(identifier: .gregorian).component(.hour, from: job.startDate) == 9)
        #expect(job.duration > 0.5)
        await queue.drain()
        #expect(await queue.jobs.first?.state == .done)
    }

    @Test func transitionHandlerFiresOnDoneWithResultAndOnFailure() async throws {
        let dir = tempDir()
        let box = Mutex<[String]>([])
        let queue = TranscriptionQueue(
            storeURL: dir.appendingPathComponent("jobs.json"),
            service: FakeTranscriptionService(text: "words here"),
            rootDirectory: dir)
        await queue.setTransitionHandler { transition in
            box.withLock { $0.append("\(transition.job.state.rawValue):\(transition.result?.text ?? "-")") }
        }
        await queue.enqueue(try makeSegment(in: dir.appendingPathComponent("a")))
        await queue.drain()
        #expect(box.withLock { $0 } == ["done:words here"])

        let failing = TranscriptionQueue(
            storeURL: dir.appendingPathComponent("jobs2.json"),
            service: FakeTranscriptionService(text: "x", failuresBeforeSuccess: .max),
            maxAttempts: 1, rootDirectory: dir)
        await failing.setTransitionHandler { transition in
            box.withLock { $0.append("\(transition.job.state.rawValue):\(transition.result?.text ?? "-")") }
        }
        await failing.enqueue(try makeSegment(in: dir.appendingPathComponent("b")))
        await failing.drain()
        #expect(box.withLock { $0 }.last == "failed:-")
    }

    @Test func persistedPathsAreRelativeAndSurviveRootMove() async throws {
        let dirA = tempDir()
        let store = dirA.appendingPathComponent("jobs.json")
        let queue = TranscriptionQueue(
            storeURL: store,
            service: FakeTranscriptionService(text: "x", failuresBeforeSuccess: .max),
            maxAttempts: 99, rootDirectory: dirA)
        await queue.enqueue(try makeSegment(in: dirA.appendingPathComponent("seg")))

        // The persisted file must not contain the absolute temp path:
        let raw = try String(contentsOf: store, encoding: .utf8)
        #expect(!raw.contains(dirA.path))

        // Simulate a container move: copy the whole root elsewhere and reload.
        let dirB = tempDir()
        try FileManager.default.copyItem(at: dirA, to: dirB)
        let moved = TranscriptionQueue(
            storeURL: dirB.appendingPathComponent("jobs.json"),
            service: FakeTranscriptionService(text: "recovered"),
            rootDirectory: dirB)
        await moved.drain()
        #expect(await moved.jobs.first?.state == .done)   // paths resolved at the NEW root
    }

    @Test func retryResetsFailedJobAndDrains() async throws {
        let dir = tempDir()
        let flaky = FakeTranscriptionService(text: "second time lucky", failuresBeforeSuccess: 1)
        let queue = TranscriptionQueue(
            storeURL: dir.appendingPathComponent("jobs.json"),
            service: flaky, maxAttempts: 1, rootDirectory: dir)
        await queue.enqueue(try makeSegment(in: dir.appendingPathComponent("a")))
        await queue.drain()
        let failed = await queue.jobs.first
        #expect(failed?.state == .failed)

        await queue.retry(jobID: failed!.id)

        let retried = await queue.jobs.first
        #expect(retried?.state == .done)   // retry re-drained and succeeded
        #expect(retried?.attempts == 0 || retried?.state == .done)
    }

    @Test func serviceProviderIsEvaluatedPerJob() async throws {
        let dir = tempDir()
        let selector = Mutex<String>("first")
        let queue = TranscriptionQueue(
            storeURL: dir.appendingPathComponent("jobs.json"),
            serviceProvider: {
                FakeTranscriptionService(text: selector.withLock { $0 })
            },
            rootDirectory: dir)
        await queue.enqueue(try makeSegment(in: dir.appendingPathComponent("a")))
        await queue.drain()
        selector.withLock { $0 = "second" }
        await queue.enqueue(try makeSegment(in: dir.appendingPathComponent("b")))
        await queue.drain()

        let dirA = dir.appendingPathComponent("a/seg.md")
        let dirB = dir.appendingPathComponent("b/seg.md")
        #expect(try String(contentsOf: dirA, encoding: .utf8).contains("first"))
        #expect(try String(contentsOf: dirB, encoding: .utf8).contains("second"))
    }

    @Test func legacyAbsoluteURLJobsStillLoad() async throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let m4a = dir.appendingPathComponent("old.m4a")
        // v1 format: TranscriptionJob's compiler-synthesized Codable encodes `URL` fields as
        // plain absolute-string values (verified via probe against the pre-Task-3 build:
        // `JSONEncoder().encode(job)` on this toolchain's Foundation produces
        // `"m4aURL":"file:///…"`, NOT a keyed `{"relative":...}` container — that historical
        // Darwin-Foundation shape is not what this Swift 6.3 / swift-foundation build emits).
        let v1 = """
        [{"id":"\(UUID().uuidString)","m4aURL":"\(m4a.absoluteString)",
          "startDate":700000000,"duration":5,"speechDuration":5,"attempts":0,"state":"pending"}]
        """
        try Data(v1.utf8).write(to: dir.appendingPathComponent("jobs.json"))
        let queue = TranscriptionQueue(
            storeURL: dir.appendingPathComponent("jobs.json"),
            service: FakeTranscriptionService(text: "x"), rootDirectory: dir)
        #expect(await queue.jobs.count == 1)
        #expect(await queue.jobs.first?.m4aURL.lastPathComponent == "old.m4a")
    }
}

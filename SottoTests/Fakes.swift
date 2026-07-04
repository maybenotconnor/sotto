import Foundation
@testable import Sotto

actor FakeAudioSource: AudioSource {
    nonisolated let sourceType: AudioSourceType = .phoneMic
    nonisolated var isAvailable: Bool { true }

    private var continuation: AsyncStream<AudioChunk>.Continuation?
    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0

    func start() async throws -> AsyncStream<AudioChunk> {
        startCallCount += 1
        let (stream, continuation) = AsyncStream.makeStream(of: AudioChunk.self)
        self.continuation = continuation
        return stream
    }

    func stop() {
        stopCallCount += 1
        continuation?.finish()
        continuation = nil
    }

    func emitSilentChunks(count: Int) {
        for _ in 0..<count {
            continuation?.yield(AudioChunk(samples: [Float](repeating: 0, count: VADConstants.chunkSize), hostTime: 0))
        }
    }

    func finish() {
        continuation?.finish()
    }
}

/// AudioSource whose start() suspends until the test releases it — for ordering races deterministically.
actor SlowStartAudioSource: AudioSource {
    nonisolated let sourceType: AudioSourceType = .phoneMic
    nonisolated var isAvailable: Bool { true }

    private var continuation: AsyncStream<AudioChunk>.Continuation?
    private var startGate: CheckedContinuation<Void, Never>?
    private var startRequested: CheckedContinuation<Void, Never>?
    private var startWasRequested = false

    func start() async throws -> AsyncStream<AudioChunk> {
        startWasRequested = true
        startRequested?.resume()
        startRequested = nil
        await withCheckedContinuation { startGate = $0 }
        let (stream, continuation) = AsyncStream.makeStream(of: AudioChunk.self)
        self.continuation = continuation
        return stream
    }

    func waitUntilStartRequested() async {
        if startWasRequested { return }
        await withCheckedContinuation { startRequested = $0 }
    }

    func releaseStart() {
        startGate?.resume()
        startGate = nil
    }

    func stop() {
        continuation?.finish()
        continuation = nil
    }

    func emitSilentChunks(count: Int) {
        for _ in 0..<count {
            continuation?.yield(AudioChunk(samples: [Float](repeating: 0, count: VADConstants.chunkSize), hostTime: 0))
        }
    }
}

/// Returns a scripted event for the Nth processed chunk (0-indexed), nil otherwise.
actor FakeSpeechDetector: SpeechDetecting {
    private let script: [Int: SpeechEvent]
    private var index = 0

    init(script: [Int: SpeechEvent]) {
        self.script = script
    }

    func process(_ chunk: AudioChunk) async throws -> SpeechEvent? {
        defer { index += 1 }
        return script[index]
    }

    func reset() {
        index = 0
    }
}

/// Records appended samples; finalize/discard bookkeeping for state-machine tests.
final class FakeSegmentWriter: SegmentWriting {
    private(set) var writtenSampleCount = 0
    private(set) var appendCalls: [Int] = []      // sample counts per append
    private(set) var finalized = false
    private(set) var discarded = false
    let m4aURL = URL(fileURLWithPath: "/tmp/fake-\(UUID().uuidString).m4a")

    func append(_ samples: [Float]) throws {
        appendCalls.append(samples.count)
        writtenSampleCount += samples.count
    }

    func finalize() throws -> URL {
        finalized = true
        return m4aURL
    }

    func discard() {
        discarded = true
    }
}

/// Hands out FakeSegmentWriters and remembers them for assertions.
final class FakeWriterFactory: SegmentWriterFactory, @unchecked Sendable {
    // @unchecked: mutated only from within the single recorder actor under test.
    private(set) var writers: [FakeSegmentWriter] = []
    private(set) var startDates: [Date] = []

    func makeWriter(startDate: Date) throws -> any SegmentWriting {
        let writer = FakeSegmentWriter()
        writers.append(writer)
        startDates.append(startDate)
        return writer
    }
}

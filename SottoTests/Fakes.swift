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

/// Scripted like FakeSpeechDetector, but THROWS for every chunk index at/after `throwFrom`.
actor ThrowingSpeechDetector: SpeechDetecting {
    struct Boom: Error {}
    private let script: [Int: SpeechEvent]
    private let throwFrom: Int
    private var index = 0

    init(script: [Int: SpeechEvent], throwFrom: Int) {
        self.script = script
        self.throwFrom = throwFrom
    }

    func process(_ chunk: AudioChunk) async throws -> SpeechEvent? {
        defer { index += 1 }
        if index >= throwFrom { throw Boom() }
        return script[index]
    }

    func reset() {
        index = 0
    }
}

/// Records appended samples; close/discard bookkeeping for state-machine tests.
final class FakeSegmentWriter: SegmentWriting {
    private(set) var writtenSampleCount = 0
    private(set) var appendCalls: [Int] = []      // sample counts per append
    private(set) var finalized = false
    private(set) var discarded = false
    let cafURL = URL(fileURLWithPath: "/tmp/fake-\(UUID().uuidString).caf")
    let m4aURL = URL(fileURLWithPath: "/tmp/fake-\(UUID().uuidString).m4a")

    func append(_ samples: [Float]) throws {
        appendCalls.append(samples.count)
        writtenSampleCount += samples.count
    }

    func close() {
        finalized = true
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

/// Scriptable recorder seam for pipeline tests: returns a scripted state per chunk index
/// and tracks ordering invariants (no chunk may be processed after finishAndFinalize).
actor FakeRecorder: SegmentRecording {
    private let stateScript: [Int: RecorderState]
    private var index = 0
    private var finished = false
    private(set) var processedChunks = 0
    private(set) var processedAfterFinish = 0
    private(set) var finishCount = 0
    private(set) var beginCount = 0
    private(set) var markInterruptedCount = 0

    init(stateScript: [Int: RecorderState] = [:]) {
        self.stateScript = stateScript
    }

    func beginListening() -> RecorderSnapshot {
        beginCount += 1
        finished = false
        index = 0
        return RecorderSnapshot(state: .listening, finalizedCount: 0, lastEvent: nil)
    }

    func process(_ chunk: AudioChunk) -> RecorderSnapshot {
        processedChunks += 1
        if finished { processedAfterFinish += 1 }
        defer { index += 1 }
        let state = stateScript[index] ?? .listening
        return RecorderSnapshot(state: state, finalizedCount: 0, lastEvent: nil)
    }

    func finishAndFinalize() -> RecorderSnapshot {
        finished = true
        finishCount += 1
        return RecorderSnapshot(state: .idle, finalizedCount: 0, lastEvent: nil)
    }

    func markInterrupted() -> RecorderSnapshot {
        markInterruptedCount += 1
        finished = true
        return RecorderSnapshot(state: .interrupted, finalizedCount: 0, lastEvent: "Interrupted")
    }
}

actor FakeNotificationScheduler: NotificationScheduling {
    private(set) var authorizationRequests = 0
    private(set) var scheduled = 0
    private(set) var cancelled = 0
    func requestAuthorizationIfNeeded() { authorizationRequests += 1 }
    func schedulePausedNotification() { scheduled += 1 }
    func cancelPausedNotification() { cancelled += 1 }
}

/// NotificationScheduling whose cancel suspends until released — for ordering races.
actor GatedNotificationScheduler: NotificationScheduling {
    private var cancelGate: CheckedContinuation<Void, Never>?
    private var cancelRequested: CheckedContinuation<Void, Never>?
    private var cancelWasRequested = false

    func requestAuthorizationIfNeeded() {}
    func schedulePausedNotification() {}

    func cancelPausedNotification() async {
        cancelWasRequested = true
        cancelRequested?.resume()
        cancelRequested = nil
        await withCheckedContinuation { cancelGate = $0 }
    }

    func waitUntilCancelRequested() async {
        if cancelWasRequested { return }
        await withCheckedContinuation { cancelRequested = $0 }
    }

    func releaseCancel() {
        cancelGate?.resume()
        cancelGate = nil
    }
}

actor FakeTranscriptionService: TranscriptionService {
    nonisolated let backend = TranscriptionBackend.speechAnalyzer
    private(set) var calls = 0
    private var remainingFailures: Int
    private let text: String

    init(text: String, failuresBeforeSuccess: Int = 0) {
        self.text = text
        self.remainingFailures = failuresBeforeSuccess
    }

    func transcribe(file: URL) async throws -> TranscriptionResult {
        calls += 1
        if remainingFailures > 0 {
            remainingFailures -= 1
            throw TranscriptionError.badResponse(500)
        }
        return TranscriptionResult(text: text, segments: [], duration: 1, backend: backend)
    }
}

@MainActor
final class FakeLiveActivityController: LiveActivityControlling {
    private(set) var startedCount = 0
    private(set) var endedCount = 0
    private(set) var endAllStaleCount = 0
    private(set) var updates: [(label: String, count: Int, paused: Bool)] = []

    func sessionStarted(at date: Date) { startedCount += 1 }
    func update(stateLabel: String, conversationCount: Int, isPaused: Bool) {
        updates.append((stateLabel, conversationCount, isPaused))
    }
    func sessionEnded() { endedCount += 1 }
    func endAllStale() { endAllStaleCount += 1 }
}

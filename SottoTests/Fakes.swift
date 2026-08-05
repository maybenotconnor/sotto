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
        // Re-arm the request latch so a second start/release cycle can be awaited (the
        // resume-path tests gate the RESTART, not just the initial start).
        startWasRequested = false
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
    private(set) var activeSource: AudioSourceType = .phoneMic
    private(set) var setActiveSourceCalls: [AudioSourceType] = []
    // M12 Task 8 reads this to assert failover source switches reach the recorder.
    private(set) var rolloverCalls: [AudioSourceType] = []

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

    func setActiveSource(_ source: AudioSourceType) {
        setActiveSourceCalls.append(source)
        activeSource = source
    }

    func rollover(to source: AudioSourceType) -> RecorderSnapshot {
        rolloverCalls.append(source)
        activeSource = source
        return RecorderSnapshot(state: .listening, finalizedCount: 0, lastEvent: nil)
    }
}

actor FakeNotificationScheduler: NotificationScheduling {
    private(set) var authorizationRequests = 0
    private(set) var scheduled = 0
    private(set) var cancelled = 0
    // M12 Task 8: counters for the source-change notification seam.
    private(set) var sourceFallbackCount = 0
    private(set) var captureUnavailableDelays: [TimeInterval] = []
    private(set) var captureUnavailableCancelCount = 0
    private(set) var lowBatteryLevels: [Int] = []
    func requestAuthorizationIfNeeded() { authorizationRequests += 1 }
    func schedulePausedNotification() { scheduled += 1 }
    func cancelPausedNotification() { cancelled += 1 }
    func scheduleSourceFallbackNotification(deviceName: String) { sourceFallbackCount += 1 }
    func scheduleCaptureUnavailableNotification(deviceName: String, delay: TimeInterval) {
        captureUnavailableDelays.append(delay)
    }
    func cancelCaptureUnavailableNotification() { captureUnavailableCancelCount += 1 }
    func scheduleLowBatteryNotification(deviceName: String, level: Int) { lowBatteryLevels.append(level) }
}

/// NotificationScheduling whose cancel suspends until released — for ordering races.
actor GatedNotificationScheduler: NotificationScheduling {
    private var cancelGate: CheckedContinuation<Void, Never>?
    private var cancelRequested: CheckedContinuation<Void, Never>?
    private var cancelWasRequested = false

    func requestAuthorizationIfNeeded() {}
    func schedulePausedNotification() {}
    func scheduleSourceFallbackNotification(deviceName: String) {}
    func scheduleCaptureUnavailableNotification(deviceName: String, delay: TimeInterval) {}
    func cancelCaptureUnavailableNotification() {}
    func scheduleLowBatteryNotification(deviceName: String, level: Int) {}

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

/// TranscriptionService whose `transcribe()` suspends mid-flight until released — lets a test
/// delete the job's m4a while a transcribe is in progress (delete-mid-transcription race,
/// M6b review Fix #3), deterministically, instead of racing a real timer against the queue.
actor GatedTranscriptionService: TranscriptionService {
    nonisolated let backend = TranscriptionBackend.speechAnalyzer
    private let text: String
    private var gate: CheckedContinuation<Void, Never>?
    private var calledContinuation: CheckedContinuation<Void, Never>?
    private var wasCalled = false

    init(text: String) { self.text = text }

    func transcribe(file: URL) async throws -> TranscriptionResult {
        wasCalled = true
        calledContinuation?.resume()
        calledContinuation = nil
        await withCheckedContinuation { gate = $0 }
        return TranscriptionResult(text: text, segments: [], duration: 1, backend: backend)
    }

    func waitUntilCalled() async {
        if wasCalled { return }
        await withCheckedContinuation { calledContinuation = $0 }
    }

    func release() {
        gate?.resume()
        gate = nil
    }
}

struct EnvironmentallyBlockedTranscriptionService: TranscriptionService {
    let backend = TranscriptionBackend.speechAnalyzer
    func transcribe(file: URL) async throws -> TranscriptionResult {
        throw TranscriptionError.unavailable
    }
}

/// Fixed-answer stand-in for `WiFiMonitor` (AppModel's `networkMonitor` seam) — avoids
/// depending on the test host's actual network state.
struct FakeNetworkMonitor: NetworkMonitoring {
    var isOnWiFi: Bool
}

actor FakeAssetInstaller: SpeechAssetInstalling {
    var installed: Bool
    var installError: Error?
    var supported = true
    private(set) var installCalls = 0

    init(installed: Bool = false) {
        self.installed = installed
    }

    func assetsInstalled() -> Bool { installed }

    func deviceSupported() -> Bool { supported }

    func install(progress: @escaping @Sendable (Double) -> Void) async throws {
        installCalls += 1
        if let installError { throw installError }
        progress(0.5)
        installed = true
        progress(1.0)
    }

    func setError(_ error: Error?) { installError = error }
    func setSupported(_ value: Bool) { supported = value }
}

struct FakePostProcessor: PostProcessor {
    var result = PostProcessingResult(
        title: "Fake standup", summary: "We discussed fakes.", actionItems: ["Ship it"], custom: nil)
    var error: Error?

    func process(transcript: TranscriptionResult, audio: URL?) async throws -> PostProcessingResult {
        if let error { throw error }
        return result
    }
}

/// PostProcessor whose `process()` suspends mid-flight until released — lets a test delete
/// the job's m4a while post-processing (notes generation) is in progress, deterministically
/// exercising the M8 hardening guard that re-checks the m4a after the notes await.
actor GatedPostProcessor: PostProcessor {
    private var gate: CheckedContinuation<Void, Never>?
    private var entered: CheckedContinuation<Void, Never>?
    private var wasEntered = false

    func process(transcript: TranscriptionResult, audio: URL?) async throws -> PostProcessingResult {
        wasEntered = true
        entered?.resume()
        entered = nil
        await withCheckedContinuation { gate = $0 }
        return PostProcessingResult(title: "Ghost", summary: nil, actionItems: nil, custom: nil)
    }

    func waitUntilEntered() async {
        if wasEntered { return }
        await withCheckedContinuation { entered = $0 }
    }

    func release() {
        gate?.resume()
        gate = nil
    }
}

@MainActor
final class FakeLiveActivityController: LiveActivityControlling {
    private(set) var startedCount = 0
    private(set) var endedCount = 0
    private(set) var endAllStaleCount = 0
    private(set) var updates: [(phase: SottoActivityAttributes.Phase, count: Int, sourceLabel: String?)] = []

    func sessionStarted(at date: Date) { startedCount += 1 }
    func update(phase: SottoActivityAttributes.Phase, conversationCount: Int, sourceLabel: String?) {
        updates.append((phase, conversationCount, sourceLabel))
    }
    func sessionEnded() { endedCount += 1 }
    func endAllStale() { endAllStaleCount += 1 }
}

/// Scriptable OmiTransport stand-in: tests drive lifecycle events and audio notifications
/// directly, with no CoreBluetooth involved.
actor FakeOmiTransport: OmiTransport {
    private var eventContinuation: AsyncStream<OmiTransportEvent>.Continuation?
    private var scanContinuation: AsyncStream<WearableDiscovery>.Continuation?
    private(set) var eventsCallCount = 0
    private(set) var stopEventsCallCount = 0
    private(set) var lastDeviceID: UUID?

    func scan() -> AsyncStream<WearableDiscovery> {
        let (stream, continuation) = AsyncStream.makeStream(of: WearableDiscovery.self)
        scanContinuation = continuation
        return stream
    }
    func stopScan() { scanContinuation?.finish(); scanContinuation = nil }

    func events(deviceID: UUID) -> AsyncStream<OmiTransportEvent> {
        eventsCallCount += 1
        lastDeviceID = deviceID
        let (stream, continuation) = AsyncStream.makeStream(of: OmiTransportEvent.self)
        eventContinuation = continuation
        return stream
    }
    func stopEvents() {
        stopEventsCallCount += 1
        eventContinuation?.finish()
        eventContinuation = nil
    }

    // Test drivers
    func emit(_ event: OmiTransportEvent) { eventContinuation?.yield(event) }
    func emitDiscovery(_ d: WearableDiscovery) { scanContinuation?.yield(d) }

    /// Emits a well-formed audio notification wrapping `payload` at `packet#`.
    func emitAudio(packet: UInt16, index: UInt8 = 0, payload: [UInt8]) {
        var data = Data([UInt8(packet & 0xFF), UInt8(packet >> 8), index])
        data.append(contentsOf: payload)
        emit(.audioNotification(data))
    }
}

/// Scriptable ConnectableAudioSource stand-in for FailoverAudioSource tests: tests drive
/// connection state directly, with no real Omi transport involved.
///
/// `stop()` mirrors the OmiAudioSource fix (M12 Task 5): it finishes — and clears — every
/// outstanding `connectionStates()` stream, not just the audio stream. Without that, a stale
/// continuation from a prior start/stop cycle would still be in `stateContinuations` and
/// would fan a later `setState()` out to a dead subscriber, double-delivering state changes
/// after a restart (Task.cancel() alone can't stop a `for await` over AsyncStream — see
/// OmiAudioSource.stop()'s doc comment).
actor FakeConnectableAudioSource: ConnectableAudioSource {
    nonisolated let sourceType: AudioSourceType = .omi
    nonisolated var isAvailable: Bool { true }
    private var continuation: AsyncStream<AudioChunk>.Continuation?
    private var stateContinuations: [UUID: AsyncStream<DeviceConnectionState>.Continuation] = [:]
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func start() async throws -> AsyncStream<AudioChunk> {
        startCount += 1
        let (stream, c) = AsyncStream.makeStream(of: AudioChunk.self)
        continuation = c
        return stream
    }
    func stop() {
        stopCount += 1
        continuation?.finish(); continuation = nil
        for c in stateContinuations.values { c.finish() }
        stateContinuations.removeAll()
    }
    func connectionStates() -> AsyncStream<DeviceConnectionState> {
        let id = UUID()
        let (stream, c) = AsyncStream.makeStream(of: DeviceConnectionState.self)
        stateContinuations[id] = c
        return stream
    }
    // Test drivers
    func setState(_ s: DeviceConnectionState) { for c in stateContinuations.values { c.yield(s) } }
    func emitChunk(_ chunk: AudioChunk) { continuation?.yield(chunk) }
}

/// Simple scriptable AudioSource for FailoverAudioSource's phone-mic side: unlike the
/// existing `FakeAudioSource`, this supports injecting a `start()` failure (needed to
/// exercise the `.captureUnavailable` path) and exposes plain `startCount`/`stopCount`.
actor FakeSimpleAudioSource: AudioSource {
    nonisolated let sourceType: AudioSourceType = .phoneMic
    nonisolated var isAvailable: Bool { true }
    private var startError: Error?
    private var continuation: AsyncStream<AudioChunk>.Continuation?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private var startDelayMS = 0
    private var stopDelayMS = 0

    func setStartError(_ error: Error?) { startError = error }
    /// Delays the start of `start()` by `ms` — lets a test suspend the caller mid-activation
    /// to race a concurrent `stop()` against it deterministically.
    func setStartDelay(_ ms: Int) { startDelayMS = ms }
    /// Delays the start of `stop()` by `ms` — lets a test suspend the caller mid-teardown to
    /// race a concurrent state event against it deterministically.
    func setStopDelay(_ ms: Int) { stopDelayMS = ms }

    func start() async throws -> AsyncStream<AudioChunk> {
        if startDelayMS > 0 { try? await Task.sleep(for: .milliseconds(startDelayMS)) }
        startCount += 1
        if let startError { throw startError }
        let (stream, c) = AsyncStream.makeStream(of: AudioChunk.self)
        continuation = c
        return stream
    }
    func stop() async {
        if stopDelayMS > 0 { try? await Task.sleep(for: .milliseconds(stopDelayMS)) }
        continuation?.finish(); continuation = nil; stopCount += 1
    }
    func emitChunk(_ chunk: AudioChunk) { continuation?.yield(chunk) }
}

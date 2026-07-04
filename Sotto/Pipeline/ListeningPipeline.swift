import Foundation
import Observation

/// M1 glue: pumps AudioChunks from the source through the pre-roll buffer and VAD,
/// and publishes status for SwiftUI. M2 replaces `Status` with the five-state
/// RecorderStateMachine; the wiring pattern here carries over.
///
/// Transitions are mutually exclusive: a `stop()` arriving while a `start()` is in
/// flight is queued and honored the moment that start completes; a `start()` arriving
/// during any in-flight transition is a no-op.
@MainActor
@Observable
final class ListeningPipeline {
    enum Status: Equatable {
        case idle
        case starting
        case listening
        case speechActive
    }

    private(set) var status: Status = .idle
    private(set) var eventLog: [String] = []

    private let source: any AudioSource
    private let detector: any SpeechDetecting
    private var preRoll: PreRollBuffer
    private var pumpTask: Task<Void, Never>?
    // Transitions are mutually exclusive: at most one start()/stop() crosses an await at a
    // time. A stop() arriving during an in-flight transition suspends until the pipeline is
    // actually idle (so stop()'s return always implies idle+drained); a start() arriving
    // during any in-flight transition is a no-op.
    private var isTransitioning = false
    private var queuedStops: [CheckedContinuation<Void, Never>] = []

    init(source: any AudioSource, detector: any SpeechDetecting, preRollSamples: Int = 16_000) {
        self.source = source
        self.detector = detector
        self.preRoll = PreRollBuffer(capacity: preRollSamples)
    }

    func start() async {
        guard status == .idle, !isTransitioning else { return }
        isTransitioning = true
        status = .starting   // truthful: no audio flows until source.start() succeeds
        do {
            let stream = try await source.start()
            status = .listening
            eventLog.append("Listening…")
            pumpTask = Task { [weak self] in
                for await chunk in stream {
                    await self?.handle(chunk)
                }
            }
        } catch {
            status = .idle
            eventLog.append("Start failed: \(error)")
        }
        isTransitioning = false
        if !queuedStops.isEmpty {
            if status == .listening {
                await performStop()      // drains, idles, then resumes the waiters
            } else {
                resumeQueuedStops()      // start failed: already idle, nothing to stop
            }
        }
    }

    func stop() async {
        if isTransitioning {
            // Suspend until the in-flight transition's deferred stop completes: callers
            // may assume the pipeline is idle and drained when stop() returns.
            await withCheckedContinuation { queuedStops.append($0) }
            return
        }
        guard status != .idle else { return }
        await performStop()
    }

    private func performStop() async {
        isTransitioning = true
        await source.stop()          // finish the stream: no new chunks after this
        await pumpTask?.value        // drain chunks already in flight to quiescence
        pumpTask = nil
        await detector.reset()
        preRoll.removeAll()
        status = .idle
        eventLog.append("Stopped")
        isTransitioning = false
        resumeQueuedStops()
    }

    private func resumeQueuedStops() {
        let waiters = queuedStops
        queuedStops = []
        for waiter in waiters {
            waiter.resume()
        }
    }

    /// Test hook: waits for the pump task to finish draining a closed stream.
    func waitUntilDrained() async {
        await pumpTask?.value
    }

    func preRollSnapshot() -> [Float] {
        preRoll.snapshot()
    }

    private func handle(_ chunk: AudioChunk) async {
        preRoll.append(chunk.samples)
        do {
            guard let event = try await detector.process(chunk) else { return }
            switch event {
            case .speechStart:
                status = .speechActive
                eventLog.append("Speech started")
            case .speechEnd:
                status = .listening
                eventLog.append("Speech ended")
            }
        } catch {
            eventLog.append("VAD error: \(error)")
        }
    }
}

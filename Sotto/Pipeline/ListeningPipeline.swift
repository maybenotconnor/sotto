import Foundation
import Observation

/// MainActor facade over the audio pipeline: owns source start/stop transitions and
/// forwards every chunk to the RecorderStateMachine actor, publishing its snapshots.
/// Transitions are mutually exclusive: at most one start()/stop() crosses an await at a
/// time. A stop() arriving during an in-flight transition suspends until the pipeline is
/// actually idle (so stop()'s return always implies idle+drained+finalized); a start()
/// arriving during any in-flight transition is a no-op.
@MainActor
@Observable
final class ListeningPipeline {
    enum Status: Equatable {
        case idle
        case starting
        case listening
        case recording
        case silence
    }

    private(set) var status: Status = .idle
    private(set) var eventLog: [String] = []
    private(set) var finalizedCount = 0

    private let source: any AudioSource
    private let recorder: any SegmentRecording
    private let heartbeat: HeartbeatStore?
    private var pumpTask: Task<Void, Never>?
    private var isTransitioning = false
    private var queuedStops: [CheckedContinuation<Void, Never>] = []

    init(
        source: any AudioSource,
        recorder: any SegmentRecording,
        heartbeat: HeartbeatStore? = nil
    ) {
        self.source = source
        self.recorder = recorder
        self.heartbeat = heartbeat
    }

    deinit {
        // Belt-and-braces: if an owner drops the pipeline without stop(), stop the source
        // so the stream finishes and the (weak-self) pump exits — otherwise the live audio
        // stack (engine, tap, VAD) would keep running with no reachable owner.
        let source = self.source
        Task.detached {
            await source.stop()
        }
    }

    func start() async {
        guard status == .idle, !isTransitioning else { return }
        isTransitioning = true
        status = .starting   // truthful: no audio flows until source.start() succeeds
        do {
            let stream = try await source.start()
            let snapshot = await recorder.beginListening()
            apply(snapshot)
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
            if status != .idle {
                await performStop()      // drains, finalizes, idles, then resumes the waiters
            } else {
                resumeQueuedStops()      // start failed: already idle, nothing to stop
            }
        }
    }

    /// When a transition is in flight, stop() queues and SUSPENDS until the deferred stop
    /// completes — stop()'s return always implies the pipeline is idle, drained, and any
    /// open segment finalized.
    func stop() async {
        if isTransitioning {
            await withCheckedContinuation { queuedStops.append($0) }
            return
        }
        guard status != .idle else { return }
        await performStop()
    }

    /// Test hook: waits for the pump task to finish draining a closed stream.
    func waitUntilDrained() async {
        await pumpTask?.value
    }

    private func performStop() async {
        isTransitioning = true
        await source.stop()          // finish the stream: no new chunks after this
        await pumpTask?.value        // drain chunks already in flight to quiescence
        pumpTask = nil
        let snapshot = await recorder.finishAndFinalize()
        apply(snapshot)
        status = .idle   // defensive; apply() above already set + heartbeat-recorded idle
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

    private func handle(_ chunk: AudioChunk) async {
        let snapshot = await recorder.process(chunk)
        apply(snapshot)
    }

    private func apply(_ snapshot: RecorderSnapshot) {
        let newStatus: Status
        switch snapshot.state {
        case .idle, .interrupted: newStatus = .idle
        case .listening: newStatus = .listening
        case .recording: newStatus = .recording
        case .silence: newStatus = .silence
        }
        if status != newStatus {
            status = newStatus
            heartbeat?.record(snapshot.state)
        }
        finalizedCount = snapshot.finalizedCount
        if let event = snapshot.lastEvent, event != eventLog.last {
            eventLog.append(event)
        }
    }
}

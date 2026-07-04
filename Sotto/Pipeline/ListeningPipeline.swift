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
        case interrupted
    }

    private(set) var status: Status = .idle
    private(set) var eventLog: [String] = []
    private(set) var finalizedCount = 0

    private let source: any AudioSource
    private let recorder: any SegmentRecording
    private let heartbeat: HeartbeatStore?
    private let liveActivity: (any LiveActivityControlling)?
    private var pumpTask: Task<Void, Never>?
    private var isTransitioning = false
    private var queuedStops: [CheckedContinuation<Void, Never>] = []
    private var pendingInterrupt = false

    init(
        source: any AudioSource,
        recorder: any SegmentRecording,
        heartbeat: HeartbeatStore? = nil,
        liveActivity: (any LiveActivityControlling)? = nil
    ) {
        self.source = source
        self.recorder = recorder
        self.heartbeat = heartbeat
        self.liveActivity = liveActivity
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
            liveActivity?.sessionStarted(at: Date())
        } catch {
            status = .idle
            eventLog.append("Start failed: \(error)")
        }
        isTransitioning = false
        if !queuedStops.isEmpty {
            pendingInterrupt = false                 // an explicit stop wins over an interrupt
            if status != .idle {
                await performHalt(.stop)
            } else {
                resumeQueuedStops()
            }
        } else if pendingInterrupt {
            pendingInterrupt = false
            if status != .idle {
                await performHalt(.interrupt)
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
        await performHalt(.stop)
    }

    /// Test hook: waits for the pump task to finish draining a closed stream.
    func waitUntilDrained() async {
        await pumpTask?.value
    }

    /// Audio interruption (.began): iOS has already stopped the engine. Finalize fast,
    /// park as .interrupted, keep the Live Activity alive showing "Paused — call".
    /// Never transcribes inline (SPEC): the recorder only finalizes; transcription is M4's queue.
    func interrupt() async {
        if isTransitioning {
            pendingInterrupt = true
            return
        }
        guard status != .idle, status != .interrupted else { return }
        await performHalt(.interrupt)
    }

    /// Recovery from .interrupted (intent tap, notification tap, or app foreground).
    func resumeFromInterruption() async {
        guard status == .interrupted, !isTransitioning else { return }
        isTransitioning = true
        status = .starting
        // Full defensive stop first: after iOS killed the engine, the source still holds a
        // non-nil engine and would throw alreadyStarted (M1 contract).
        await source.stop()
        do {
            let stream = try await source.start()
            let snapshot = await recorder.beginListening()
            apply(snapshot)
            eventLog.append("Resumed")
            pumpTask = Task { [weak self] in
                for await chunk in stream {
                    await self?.handle(chunk)
                }
            }
        } catch {
            status = .interrupted
            eventLog.append("Resume failed: \(error)")
        }
        isTransitioning = false
        if !queuedStops.isEmpty {
            pendingInterrupt = false
            if status != .idle {
                await performHalt(.stop)
            } else {
                resumeQueuedStops()
            }
        } else if pendingInterrupt {
            pendingInterrupt = false
            if status == .listening {
                await performHalt(.interrupt)
            }
        }
    }

    /// Entry point for the Live Activity intent / notification tap.
    func toggleFromIntent() async {
        switch status {
        case .idle: await start()
        case .interrupted: await resumeFromInterruption()
        default: await stop()
        }
    }

    private enum HaltMode { case stop, interrupt }

    private func performHalt(_ mode: HaltMode) async {
        isTransitioning = true
        await source.stop()          // finish the stream: no new chunks after this
        await pumpTask?.value        // drain chunks already in flight to quiescence
        pumpTask = nil
        switch mode {
        case .stop:
            let snapshot = await recorder.finishAndFinalize()
            apply(snapshot)
            status = .idle   // defensive; apply() already set + heartbeat-recorded idle
            eventLog.append("Stopped")
            liveActivity?.sessionEnded()
        case .interrupt:
            let snapshot = await recorder.markInterrupted()
            apply(snapshot)
            eventLog.append("Paused — call")
        }
        isTransitioning = false
        // Reconcile requests that arrived during this halt, regardless of entry point:
        // an explicit stop always wins and must leave the pipeline idle+finalized before
        // its waiters resume; a pending interrupt against an idle/interrupted pipeline
        // is meaningless and must not leak into a future session.
        if !queuedStops.isEmpty && status != .idle {
            pendingInterrupt = false
            await performHalt(.stop)   // bounded recursion: the inner halt ends at .idle
            return                     // the inner call resumed the waiters
        }
        pendingInterrupt = false
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
        case .idle: newStatus = .idle
        case .interrupted: newStatus = .interrupted
        case .listening: newStatus = .listening
        case .recording: newStatus = .recording
        case .silence: newStatus = .silence
        }
        if status != newStatus {
            status = newStatus
            heartbeat?.record(snapshot.state)
            liveActivity?.update(
                stateLabel: Self.activityLabel(for: newStatus),
                conversationCount: snapshot.finalizedCount,
                isPaused: newStatus == .interrupted)
        }
        finalizedCount = snapshot.finalizedCount
        if let event = snapshot.lastEvent, event != eventLog.last {
            eventLog.append(event)
        }
    }

    static func activityLabel(for status: Status) -> String {
        switch status {
        case .idle: "Stopped"
        case .starting: "Starting…"
        case .listening: "Listening"
        case .recording: "Recording"
        case .silence: "Listening"
        case .interrupted: "Paused — call"
        }
    }
}

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

    /// Why the pipeline is currently .interrupted — drives both the Live Activity/event-log
    /// label and whether a fallback "resume?" notification makes sense (a user-initiated
    /// pause needs no nag; a system interruption does).
    enum HaltReason: Sendable, Equatable {
        case systemInterruption
        case userPause
    }

    private(set) var status: Status = .idle
    private(set) var eventLog: [String] = []
    private(set) var finalizedCount = 0
    /// Non-nil only while status == .interrupted.
    private(set) var haltReason: HaltReason?
    /// Mirrors the recorder's disk-guard flag (M6b Main screen banner) — set from `apply()`.
    private(set) var diskGuardActive = false
    /// When the current session began (SPEC Main screen elapsed-time display). Set once on a
    /// successful `start()`; survives interruption/resume (the session hasn't ended, just
    /// paused) and only clears back to nil when the session actually stops.
    private(set) var sessionStartedAt: Date?
    /// M9: mirrors the recorder's currently-open-segment start date (unified home's live
    /// "Recording…" row timer) — set from `apply()`.
    private(set) var currentSegmentStartDate: Date?
    /// M12: which device is currently capturing (nil when idle or nothing capturing). For a
    /// plain (non-switching) source this is just `source.sourceType`, set once on start(); for
    /// a `SourceSwitchingAudioSource` (FailoverAudioSource) it tracks `sourceChanges()`.
    private(set) var activeSourceType: AudioSourceType?

    private let source: any AudioSource
    private let recorder: any SegmentRecording
    private let heartbeat: HeartbeatStore?
    private let liveActivity: (any LiveActivityControlling)?
    private let notifications: (any NotificationScheduling)?
    private var pumpTask: Task<Void, Never>?
    private var sourceEventTask: Task<Void, Never>?
    private var isTransitioning = false
    private var queuedStops: [CheckedContinuation<Void, Never>] = []
    private var pendingPark: HaltReason?
    /// Dedup for the loud "nothing capturing" notification. `activeSourceType == nil` is
    /// overloaded (both "never activated" and "already notified"), so a nil-check alone would
    /// silently drop the very FIRST `.captureUnavailable` event on a cold start (Omi loses the
    /// startup race AND phoneMic.start() throws immediately) — the one signal that nothing is
    /// recording. Cleared on every successful activation and on a full stop().
    private var hasNotifiedCaptureUnavailable = false

    init(
        source: any AudioSource,
        recorder: any SegmentRecording,
        heartbeat: HeartbeatStore? = nil,
        liveActivity: (any LiveActivityControlling)? = nil,
        notifications: (any NotificationScheduling)? = nil
    ) {
        self.source = source
        self.recorder = recorder
        self.heartbeat = heartbeat
        self.liveActivity = liveActivity
        self.notifications = notifications
    }

    deinit {
        // Belt-and-braces: if an owner drops the pipeline without stop(), stop the source
        // so the stream finishes and the (weak-self) pump exits — otherwise the live audio
        // stack (engine, tap, VAD) would keep running with no reachable owner.
        // The Live Activity is NOT ended here (MainActor-isolated controller is unreachable
        // from deinit); the launch-time endAllStale() sweep covers it.
        let source = self.source
        Task.detached {
            await source.stop()
        }
    }

    func start() async {
        guard status == .idle, !isTransitioning else { return }
        isTransitioning = true
        status = .starting   // truthful: no audio flows until source.start() succeeds
        // Subscribe to source changes BEFORE source.start(): sourceChanges() registers its
        // continuation on first demand inside this task, and a change emitted before that
        // registration goes to zero continuations and is LOST — including the very first
        // activation when the source resolves fast (Omi already streaming at startup), which
        // would leave activeSourceType nil and the recorder's source label stale for the
        // whole session. Creating the task here enqueues it ahead of start()'s resume on the
        // MainActor, so the subscription lands before any event the started source can emit.
        if let switching = source as? any SourceSwitchingAudioSource {
            sourceEventTask = Task { [weak self] in
                for await change in await switching.sourceChanges() {
                    await self?.handleSourceChange(change)
                }
            }
        }
        do {
            let stream = try await source.start()
            let snapshot = await recorder.beginListening()
            apply(snapshot)
            log("Listening…")
            pumpTask = Task { [weak self] in
                for await chunk in stream {
                    await self?.handle(chunk)
                }
            }
            if !(source is any SourceSwitchingAudioSource) {
                activeSourceType = source.sourceType
                Task { await recorder.setActiveSource(source.sourceType) }
            }
            await notifications?.requestAuthorizationIfNeeded()
            sessionStartedAt = Date()
            liveActivity?.sessionStarted(at: Date())
        } catch {
            status = .idle
            // The source never started, so no change is mid-handleSourceChange; cancellation
            // IS honored at the for-await's suspension point (the drain-before-finalize rule
            // in performHalt exists for bodies already resumed, which can't exist here).
            sourceEventTask?.cancel()
            sourceEventTask = nil
            log("Start failed: \(error)")
        }
        isTransitioning = false
        if !queuedStops.isEmpty {
            pendingPark = nil                 // an explicit stop wins over an interrupt
            if status != .idle {
                await performHalt(.stop)
            } else {
                resumeQueuedStops()
            }
        } else if let reason = pendingPark {
            pendingPark = nil
            if status != .idle {
                await performHalt(.park(reason))
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
            pendingPark = .systemInterruption
            return
        }
        guard status != .idle, status != .interrupted else { return }
        await performHalt(.park(.systemInterruption))
    }

    /// User-initiated pause (Live Activity / intent toggle while active). Unlike interrupt(),
    /// this is a deliberate choice — no fallback "resume?" notification nags the user about
    /// something they did on purpose, but the activity survives so Resume still works.
    func pauseByUser() async {
        if isTransitioning {
            pendingPark = .userPause
            return
        }
        guard status != .idle, status != .interrupted else { return }
        await performHalt(.park(.userPause))
    }

    /// Recovery from .interrupted (intent tap, notification tap, or app foreground).
    func resumeFromInterruption() async {
        guard status == .interrupted, !isTransitioning else { return }
        isTransitioning = true
        status = .starting
        // Full defensive stop first: after iOS killed the engine, the source still holds a
        // non-nil engine and would throw alreadyStarted (M1 contract).
        await source.stop()
        // Subscribe BEFORE source.start() (see start() for the lost-first-event rationale) —
        // but AFTER the defensive stop above, which finishes any previously registered
        // change continuations.
        if let switching = source as? any SourceSwitchingAudioSource {
            sourceEventTask = Task { [weak self] in
                for await change in await switching.sourceChanges() {
                    await self?.handleSourceChange(change)
                }
            }
        }
        do {
            let stream = try await source.start()
            let snapshot = await recorder.beginListening()
            apply(snapshot)
            haltReason = nil
            log("Resumed")
            pumpTask = Task { [weak self] in
                for await chunk in stream {
                    await self?.handle(chunk)
                }
            }
            if !(source is any SourceSwitchingAudioSource) {
                activeSourceType = source.sourceType
                Task { await recorder.setActiveSource(source.sourceType) }
            }
            await notifications?.cancelPausedNotification()
        } catch {
            status = .interrupted
            sourceEventTask?.cancel()   // see start()'s catch: no body can be in flight here
            sourceEventTask = nil
            log("Resume failed: \(error)")
        }
        isTransitioning = false
        if !queuedStops.isEmpty {
            pendingPark = nil
            if status != .idle {
                await performHalt(.stop)
            } else {
                resumeQueuedStops()
            }
        } else if let reason = pendingPark {
            pendingPark = nil
            // .recording/.silence count too: a chunk processed during resume's own awaits can
            // advance status past .listening, and dropping the interrupt then leaves a
            // live-looking UI over a dead engine. Only idle/interrupted make it moot.
            if status != .idle && status != .interrupted {
                await performHalt(.park(reason))
            }
        }
    }

    /// Entry point for the Live Activity intent / notification tap. Unlike the in-app Stop
    /// button (which always fully stops), the "else" branch here parks as a user-initiated
    /// pause — the Live Activity survives so a subsequent tap can Resume.
    func toggleFromIntent() async {
        switch status {
        case .idle: await start()
        case .interrupted: await resumeFromInterruption()
        default: await pauseByUser()
        }
    }

    private enum HaltMode { case stop, park(HaltReason) }

    private func performHalt(_ mode: HaltMode) async {
        isTransitioning = true
        await source.stop()          // finish the stream: no new chunks after this
        await pumpTask?.value        // drain chunks already in flight to quiescence
        pumpTask = nil
        // source.stop() above already finished sourceChanges(); we rely on that finish+drain
        // (not task cancellation) so an already-buffered/in-flight handleSourceChange (e.g.
        // recorder.rollover(to:) + apply(snapshot) reporting .listening) still gets to run to
        // completion instead of being dropped mid-flight — which matters here because it could
        // otherwise land AFTER finishAndFinalize() below sets status to .idle, reverting it.
        // Await the drain so it fully resolves BEFORE finalizing (no deadlock: both run on
        // MainActor, and awaiting .value suspends performHalt, freeing the actor for
        // handleSourceChange calls still in flight; the loop itself ends because source.stop()
        // finished the stream).
        await sourceEventTask?.value
        sourceEventTask = nil
        switch mode {
        case .stop:
            let snapshot = await recorder.finishAndFinalize()
            apply(snapshot)
            status = .idle   // defensive; apply() already set + heartbeat-recorded idle
            haltReason = nil
            sessionStartedAt = nil
            activeSourceType = nil
            hasNotifiedCaptureUnavailable = false
            log("Stopped")
            liveActivity?.sessionEnded()
            await notifications?.cancelPausedNotification()
        case .park(let reason):
            // Set BEFORE apply(): apply()'s status-change branch reads haltReason to pick
            // the Live Activity label for the (about to be entered) .interrupted status.
            haltReason = reason
            let snapshot = await recorder.markInterrupted()
            apply(snapshot)
            log(reason == .userPause ? "Paused by you" : "Paused — call")
            if reason == .systemInterruption {
                // A user-initiated pause needs no fallback nag — they know they paused it.
                await notifications?.schedulePausedNotification()
            }
        }
        isTransitioning = false
        // Reconcile requests that arrived during this halt, regardless of entry point:
        // an explicit stop always wins and must leave the pipeline idle+finalized before
        // its waiters resume; a pending interrupt against an idle/interrupted pipeline
        // is meaningless and must not leak into a future session.
        if !queuedStops.isEmpty && status != .idle {
            pendingPark = nil
            await performHalt(.stop)   // bounded recursion: the inner halt ends at .idle
            return                     // the inner call resumed the waiters
        }
        pendingPark = nil
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

    /// M12: reacts to a `SourceSwitchingAudioSource`'s `sourceChanges()` stream. Rare race
    /// (FailoverAudioSource RACE B recovery) can redeliver the SAME source with the SAME
    /// reason back-to-back (e.g. two `.phoneMic`/`.wearableDisconnected` events with no
    /// intervening recovery) — `recorder.rollover(to:)` is still called every time (a no-op
    /// finalize-wise when nothing is open), but the log line and user-facing notification are
    /// gated on the source actually having changed, so a repeat never double-notifies.
    private func handleSourceChange(_ change: AudioSourceChange) async {
        let previousSource = activeSourceType
        switch change.reason {
        case .initial:
            if let source = change.source {
                activeSourceType = source
                hasNotifiedCaptureUnavailable = false
                await recorder.setActiveSource(source)
                log("Capturing via \(source.displayName)")
            }
        case .wearableDisconnected:
            guard let source = change.source else { return }
            let snapshot = await recorder.rollover(to: source)
            activeSourceType = source
            hasNotifiedCaptureUnavailable = false
            apply(snapshot)
            if previousSource != source {
                log("Omi disconnected — continuing on iPhone mic")
                await notifications?.scheduleSourceFallbackNotification()
            }
        case .wearableRecovered:
            guard let source = change.source else { return }
            let snapshot = await recorder.rollover(to: source)
            activeSourceType = source
            hasNotifiedCaptureUnavailable = false
            apply(snapshot)
            if previousSource != source {
                log("Omi reconnected")
            }
        case .captureUnavailable:
            activeSourceType = nil
            if !hasNotifiedCaptureUnavailable {
                hasNotifiedCaptureUnavailable = true
                log("Nothing capturing — Omi gone and mic unavailable")
                await notifications?.scheduleCaptureUnavailableNotification()
            }
        }
        pushLiveActivitySource()
    }

    /// Pushes a Live Activity update carrying the fresh `activeSourceType` even when
    /// status/finalizedCount didn't change (a rollover mid-.listening is exactly that case) —
    /// `apply()`'s own update calls only fire on a status or count transition.
    private func pushLiveActivitySource() {
        if let phase = activityPhase(for: status) {
            liveActivity?.update(phase: phase, conversationCount: finalizedCount,
                                 sourceLabel: liveActivitySourceLabel)
        }
    }

    /// M12 Task 12: the Live Activity only gets a source label when the source can actually
    /// switch (i.e. an Omi is paired). `activeSourceType` is stamped for a plain phone-mic
    /// pipeline too (the recorder's segment tagging needs the accurate value — see that
    /// property's doc comment), but surfacing "iPhone mic" on every lock-screen update would
    /// be new, unwanted chatter for the vast majority of users who never paired an Omi. This
    /// pipeline has no direct handle on `AppModel.pairedDeviceName` (mirrors the home header's
    /// gate — ContentView), but "source can switch" is an equivalent proxy here: only
    /// `FailoverAudioSource` conforms to `SourceSwitchingAudioSource`, and `AppModel` only
    /// constructs one when an Omi is actually paired.
    private var liveActivitySourceLabel: String? {
        (source is any SourceSwitchingAudioSource) ? activeSourceType?.displayName : nil
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
            if let phase = activityPhase(for: newStatus) {
                liveActivity?.update(phase: phase, conversationCount: snapshot.finalizedCount,
                                     sourceLabel: liveActivitySourceLabel)
            }
        } else if finalizedCount != snapshot.finalizedCount {
            // Status-unchanged path: the branch above already pushed the fresh count when
            // status ALSO changed, so this only fires standalone — no double update.
            if let phase = activityPhase(for: status) {
                liveActivity?.update(phase: phase, conversationCount: snapshot.finalizedCount,
                                     sourceLabel: liveActivitySourceLabel)
            }
        }
        finalizedCount = snapshot.finalizedCount
        diskGuardActive = snapshot.diskGuardActive
        currentSegmentStartDate = snapshot.currentSegmentStartDate
        if let event = snapshot.lastEvent {
            log(event)
        }
    }

    /// Unbounded growth over a long-running session would be a slow memory leak (M2
    /// carryover) — the in-app list only ever shows the tail anyway. Every append site
    /// routes through here so the cap and back-to-back dedupe are always applied.
    private func log(_ line: String) {
        if line == eventLog.last { return }
        eventLog.append(line)
        if eventLog.count > 200 {
            eventLog.removeFirst(eventLog.count - 200)
        }
    }

    /// Instance (not static): the paused cases depend on `haltReason`, which is
    /// per-pipeline state, not derivable from `status` alone. Returns nil for
    /// idle/starting — there is nothing meaningful to render (idle is immediately
    /// followed by sessionEnded(), and starting resolves to listening within the tick).
    func activityPhase(for status: Status) -> SottoActivityAttributes.Phase? {
        switch status {
        case .idle, .starting: nil
        case .listening, .silence: .listening
        case .recording: .recording
        case .interrupted: haltReason == .userPause ? .pausedByUser : .pausedBySystem
        }
    }
}

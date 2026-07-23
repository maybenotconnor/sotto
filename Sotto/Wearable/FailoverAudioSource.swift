import Foundation
import os

struct FailoverConfig: Sendable {
    var reconnectGrace: Duration = .seconds(3)
    var returnHysteresis: Duration = .seconds(10)
}

enum AudioSourceChangeReason: Sendable, Equatable {
    case initial, wearableDisconnected, wearableRecovered, captureUnavailable
}

struct AudioSourceChange: Sendable, Equatable {
    let source: AudioSourceType?   // nil ⇒ nothing capturing (captureUnavailable)
    let reason: AudioSourceChangeReason
}

protocol SourceSwitchingAudioSource: AudioSource {
    func sourceChanges() async -> AsyncStream<AudioSourceChange>
    var activeSourceType: AudioSourceType? { get async }
}

/// Route-change forwarding seam (AppModel wiring, Task 10).
protocol RouteChangeHandling: Sendable {
    func rebuildTap() async throws
}

extension PhoneMicAudioSource: RouteChangeHandling {}

/// Prefers the wearable whenever it streams; phone mic otherwise. Presents ONE chunk
/// stream, the pipeline can't tell sources apart (by design — SPEC audio source layer).
///
/// Concurrency notes:
/// - Timer tasks (grace / hysteresis) are event-cancelled (the state event
///   that supersedes a timer cancels it) AND self-guard on `started`/`activeSourceType`
///   before acting, so a stale timer that already escaped cancellation (e.g. it fired
///   concurrently with `stop()`, or during an actor-reentrant window while `stop()` awaits
///   a child `stop()`) is a harmless no-op rather than a corrupting write.
/// - `handle(_:)` itself guards on `started` for the same reason: child sources (real and
///   fake) finish their `connectionStates()` streams from inside their `stop()`, and we rely
///   on that finish+drain (not task cancellation) so any already-buffered event still
///   delivers — our `stateTask` can still receive one more buffered event reentrantly while
///   `FailoverAudioSource.stop()` is suspended awaiting `wearable.stop()`. That event must
///   not spawn a new grace/return timer.
/// - Both child sources are drained unconditionally for as long as this source is started;
///   `forward(_:from:)` only forwards while that source is the active one, so the inactive
///   child's stream is drained-and-dropped rather than buffered.
actor FailoverAudioSource: SourceSwitchingAudioSource {
    /// Informational: the preferred source — whatever wearable family this failover
    /// fronts (was hardcoded `.omi` before the seam generalization).
    nonisolated let sourceType: AudioSourceType
    nonisolated var isAvailable: Bool { true }

    enum FailoverError: Error { case alreadyStarted }

    private let wearable: any ConnectableAudioSource
    private let phoneMic: any AudioSource
    private let config: FailoverConfig
    /// Diagnostics for the reported "no iPhone-mic fallback while foregrounded" mystery
    /// (2026-07-21): the event log that narrates these decisions is not surfaced anywhere,
    /// so mirror every failover decision to os_log until the root cause is confirmed.
    private let logger = Logger(subsystem: "app.decanlys.sotto", category: "Failover")

    private(set) var activeSourceType: AudioSourceType?
    private var outward: AsyncStream<AudioChunk>.Continuation?
    private var changeContinuations: [UUID: AsyncStream<AudioSourceChange>.Continuation] = [:]

    private var wearablePumpTask: Task<Void, Never>?
    private var micPumpTask: Task<Void, Never>?
    private var stateTask: Task<Void, Never>?
    private var graceTask: Task<Void, Never>?
    private var returnTask: Task<Void, Never>?
    private var started = false

    /// Bumped at the top of every `start()`/`stop()`. Activation callbacks that suspend on a
    /// cross-actor await (`activatePhoneMic`, `returnHysteresisElapsed`) capture the generation
    /// beforehand and re-check it after resuming, so a `stop()` (or restart) that ran to
    /// completion during the suspension is detected instead of silently clobbered — see the
    /// concurrency notes above `handle(_:)`.
    private var generation = 0
    /// Mirrors the most recent `DeviceConnectionState` delivered to `handle(_:)`. Lets
    /// `returnHysteresisElapsed()` tell, after resuming from a suspended `phoneMic.stop()`,
    /// whether the wearable is still genuinely streaming or dropped again during that window.
    private var lastWearableState: DeviceConnectionState = .disconnected

    /// Tracks whether any source has EVER been successfully activated. Distinguishes the
    /// very first activation (`.initial`) from a later nil→active transition that follows
    /// a `.captureUnavailable` gap (`.wearableRecovered`) — see `activate(_:reason:)`.
    private var hasEmittedInitial = false

    /// Spec §1: distinguishes the FIRST `.streaming` of a session (upgrade immediately —
    /// nothing to distrust yet) from a post-failure return (10 s hysteresis). In-memory,
    /// per-session; `hasEmittedInitial` cannot serve — under mic-first the mic sets it
    /// almost immediately every session.
    private var wearableWasActiveThisSession = false

    init(wearable: any ConnectableAudioSource, phoneMic: any AudioSource,
         config: FailoverConfig = FailoverConfig()) {
        self.wearable = wearable
        self.phoneMic = phoneMic
        self.config = config
        self.sourceType = wearable.sourceType
    }

    func start() async throws -> AsyncStream<AudioChunk> {
        guard !started else { throw FailoverError.alreadyStarted }
        generation += 1
        started = true
        logger.notice("start: mic-first, \(self.sourceType.displayName, privacy: .public) upgrades when streaming")
        activeSourceType = nil
        hasEmittedInitial = false
        wearableWasActiveThisSession = false
        lastWearableState = .disconnected
        let (stream, continuation) = AsyncStream.makeStream(of: AudioChunk.self)
        outward = continuation

        let states = await wearable.connectionStates()
        let wearableStream = try await wearable.start()
        // Always drain the wearable stream; forward only while the wearable is active
        // (prevents unbounded buffering while on fallback).
        wearablePumpTask = Task { [weak self, sourceType] in
            for await chunk in wearableStream {
                await self?.forward(chunk, from: sourceType)
            }
        }
        stateTask = Task { [weak self] in
            for await state in states {
                await self?.handle(state)
            }
        }
        // Mic-first (redesign spec §1): Start's tap is the only guaranteed-foreground
        // moment, and iOS forbids STARTING capture from the background — so the mic
        // starts NOW, with no timer in between. The wearable upgrades on its first
        // `.streaming`. Never throws: a failed mic start is the first waiting entry
        // (.captureUnavailable), not a failed session.
        await activatePhoneMic(reason: .initial)
        return stream
    }

    func stop() async {
        generation += 1
        started = false
        logger.notice("stop")
        for task in [wearablePumpTask, micPumpTask, stateTask, graceTask, returnTask] {
            task?.cancel()
        }
        wearablePumpTask = nil; micPumpTask = nil; stateTask = nil
        graceTask = nil; returnTask = nil
        await wearable.stop()
        await phoneMic.stop()
        activeSourceType = nil
        outward?.finish()
        outward = nil
        for continuation in changeContinuations.values { continuation.finish() }
        changeContinuations = [:]
    }

    func sourceChanges() -> AsyncStream<AudioSourceChange> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: AudioSourceChange.self)
        changeContinuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeChangeContinuation(id) }
        }
        return stream
    }

    /// Forwards to the phone mic's tap rebuild when it's the active source; no-op otherwise
    /// (the wearable has no comparable route-change dependency — it's a BLE peripheral, not
    /// an AVAudioSession input route).
    func handleRouteChange() async throws {
        guard activeSourceType == .phoneMic,
              let handler = phoneMic as? any RouteChangeHandling else { return }
        try await handler.rebuildTap()
    }

    private func removeChangeContinuation(_ id: UUID) { changeContinuations[id] = nil }

    private func forward(_ chunk: AudioChunk, from source: AudioSourceType) {
        guard activeSourceType == source else { return }   // drain-and-drop inactive source
        outward?.yield(chunk)
    }

    private func emit(_ change: AudioSourceChange) {
        for continuation in changeContinuations.values { continuation.yield(change) }
    }

    private func handle(_ state: DeviceConnectionState) async {
        // Guards the actor-reentrant window during `stop()`: a child source finishes its
        // connectionStates() stream from inside its own `stop()`, and our `stateTask` can
        // still deliver one buffered event while `FailoverAudioSource.stop()` is itself
        // suspended awaiting that child `stop()`. `started` is set false synchronously at
        // the top of `stop()`, before any suspension, so this guard closes that window.
        guard started else { return }
        lastWearableState = state
        logger.notice("wearable state: \(String(describing: state), privacy: .public), active: \(self.activeSourceType?.displayName ?? "none", privacy: .public)")
        switch state {
        case .streaming:
            graceTask?.cancel(); graceTask = nil
            if activeSourceType == nil {
                // Waiting (or the instant before the inline mic activation lands): rescue
                // immediately — hysteresis never delays recovery from zero capture (spec §1).
                activate(sourceType, reason: .initial)
            } else if activeSourceType == .phoneMic, returnTask == nil {
                // First streaming of the session upgrades immediately (zero delay); a wearable
                // that already failed this session must prove itself for the full hysteresis.
                // Routed through the SAME returnTask machinery either way: switchToWearable then
                // runs OFF the state loop, so a drop that lands during its suspended
                // phoneMic.stop() is still observed (RACE B) instead of being queued behind it.
                armReturnTimer(after: wearableWasActiveThisSession ? config.returnHysteresis : .zero)
            }
        case .disconnected, .unavailable:
            returnTask?.cancel(); returnTask = nil
            if activeSourceType == sourceType, graceTask == nil {
                graceTask = Task { [weak self, config] in
                    try? await Task.sleep(for: config.reconnectGrace)
                    guard !Task.isCancelled else { return }
                    await self?.graceExpired()
                }
            }
        case .connecting, .connected:
            break
        }
    }

    private func graceExpired() async {
        graceTask = nil
        logger.notice("reconnect grace expired, started: \(self.started), active: \(self.activeSourceType?.displayName ?? "none", privacy: .public)")
        guard started, activeSourceType == sourceType else { return }
        await activatePhoneMic(reason: .wearableDisconnected)
    }

    private func armReturnTimer(after delay: Duration) {
        returnTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.returnHysteresisElapsed()
        }
    }

    private func returnHysteresisElapsed() async {
        returnTask = nil
        logger.notice("return hysteresis elapsed, started: \(self.started), active: \(self.activeSourceType?.displayName ?? "none", privacy: .public)")
        guard started, activeSourceType == .phoneMic else { return }
        await switchToWearable()
    }

    /// Stops the mic and hands capture to the wearable — shared by the first-upgrade path
    /// (immediately on `.streaming`) and the post-failure return (after the hysteresis).
    /// Re-checks after the suspended `phoneMic.stop()` (RACE B — see the concurrency notes
    /// above `handle(_:)`): the wearable may have dropped again during the suspension, in
    /// which case the mic is restarted rather than claiming a dead wearable.
    private func switchToWearable() async {
        let gen = generation
        micPumpTask?.cancel(); micPumpTask = nil
        await phoneMic.stop()
        guard generation == gen, started else { return }
        if lastWearableState == .streaming {
            activate(sourceType, reason: .wearableRecovered)
        } else {
            await activatePhoneMic(reason: .wearableDisconnected)
        }
    }

    private func activate(_ source: AudioSourceType, reason: AudioSourceChangeReason) {
        logger.notice("activating \(source.displayName, privacy: .public) (reason: \(String(describing: reason), privacy: .public))")
        activeSourceType = source
        if source == sourceType { wearableWasActiveThisSession = true }
        // A nil→active transition after the very first activation is a RECOVERY (from
        // .captureUnavailable), even though the triggering code path also calls it with
        // reason: .initial (activatePhoneMic and the streaming-wins-the-race branch above
        // don't know whether this is the first activation ever).
        let effectiveReason: AudioSourceChangeReason = (reason == .initial && hasEmittedInitial) ? .wearableRecovered : reason
        hasEmittedInitial = true
        emit(AudioSourceChange(source: source, reason: effectiveReason))
    }

    private func activatePhoneMic(reason: AudioSourceChangeReason) async {
        let gen = generation
        let expectedSource = activeSourceType
        logger.notice("starting phone mic (reason: \(String(describing: reason), privacy: .public))")
        do {
            let stream = try await phoneMic.start()
            // RACE A + activation clobber (spec §1 hardening): a stop()/restart, OR a
            // wearable activation (handle(.streaming)'s nil branch), may have run while
            // `phoneMic.start()` was suspended above. Undo the orphaned start rather than
            // clobbering the current source. Common under mic-first: a wearable that is
            // already in range can stream during the inline start-up mic activation.
            guard generation == gen, started, activeSourceType == expectedSource else {
                await phoneMic.stop()
                return
            }
            micPumpTask = Task { [weak self] in
                for await chunk in stream {
                    await self?.forward(chunk, from: .phoneMic)
                }
            }
            activate(.phoneMic, reason: reason)
            // The wearable may have STARTED streaming during the suspended mic start while
            // a previous source was still nominally active (grace path) — that `.streaming`
            // edge was consumed and will not re-fire, so arm the return path from the
            // recorded level here.
            if lastWearableState == .streaming, returnTask == nil {
                armReturnTimer(after: wearableWasActiveThisSession ? config.returnHysteresis : .zero)
            }
        } catch {
            logger.error("phone mic start FAILED: \(String(describing: error), privacy: .public)")
            // Same re-check as the success path: a wearable that activated during the
            // suspended mic start is LIVE — a mic failure then must not clobber it into
            // a false "nothing capturing" (it would stick: .streaming is edge-triggered).
            guard generation == gen, started, activeSourceType == expectedSource else { return }
            if activeSourceType == sourceType, lastWearableState == .streaming {
                // The wearable recovered during the suspended (failed) mic start — that
                // .streaming edge is consumed and won't re-fire. Keep the live wearable
                // active instead of clobbering it into a stuck "nothing capturing".
                return
            }
            graceTask?.cancel(); graceTask = nil   // no timers run while waiting (spec §1)
            activeSourceType = nil
            emit(AudioSourceChange(source: nil, reason: .captureUnavailable))
        }
    }
}

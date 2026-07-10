import Foundation

struct FailoverConfig: Sendable {
    var startupRace: Duration = .seconds(3)
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
/// - Timer tasks (startup race / grace / hysteresis) are event-cancelled (the state event
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

    private(set) var activeSourceType: AudioSourceType?
    private var outward: AsyncStream<AudioChunk>.Continuation?
    private var changeContinuations: [UUID: AsyncStream<AudioSourceChange>.Continuation] = [:]

    private var wearablePumpTask: Task<Void, Never>?
    private var micPumpTask: Task<Void, Never>?
    private var stateTask: Task<Void, Never>?
    private var startupTask: Task<Void, Never>?
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
        activeSourceType = nil
        hasEmittedInitial = false
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
        startupTask = Task { [weak self, config] in
            try? await Task.sleep(for: config.startupRace)
            guard !Task.isCancelled else { return }
            await self?.startupRaceExpired()
        }
        return stream
    }

    func stop() async {
        generation += 1
        started = false
        for task in [wearablePumpTask, micPumpTask, stateTask, startupTask, graceTask, returnTask] {
            task?.cancel()
        }
        wearablePumpTask = nil; micPumpTask = nil; stateTask = nil
        startupTask = nil; graceTask = nil; returnTask = nil
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
        switch state {
        case .streaming:
            graceTask?.cancel(); graceTask = nil
            if activeSourceType == nil {                  // won the startup race
                startupTask?.cancel(); startupTask = nil
                activate(sourceType, reason: .initial)
            } else if activeSourceType == .phoneMic, returnTask == nil {
                returnTask = Task { [weak self, config] in
                    try? await Task.sleep(for: config.returnHysteresis)
                    guard !Task.isCancelled else { return }
                    await self?.returnHysteresisElapsed()
                }
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

    private func startupRaceExpired() async {
        startupTask = nil
        guard started, activeSourceType == nil else { return }
        await activatePhoneMic(reason: .initial)
    }

    private func graceExpired() async {
        graceTask = nil
        guard started, activeSourceType == sourceType else { return }
        await activatePhoneMic(reason: .wearableDisconnected)
    }

    private func returnHysteresisElapsed() async {
        returnTask = nil
        guard started else { return }
        guard activeSourceType == .phoneMic else {
            // Recovery path from captureUnavailable: activeSourceType is nil there too, but
            // that transition is driven directly by `handle(.streaming)`, not this timer.
            return
        }
        let gen = generation
        micPumpTask?.cancel(); micPumpTask = nil
        await phoneMic.stop()
        // A concurrent stop()/restart may have run to completion while we were suspended above
        // (RACE B — see the concurrency notes above `handle(_:)`); re-check before acting.
        guard generation == gen, started else { return }
        if lastWearableState == .streaming {
            activate(sourceType, reason: .wearableRecovered)
        } else {
            // The wearable dropped again during the suspended phoneMic.stop() — claiming it
            // active would leave nothing capturing. Restart the mic instead.
            await activatePhoneMic(reason: .wearableDisconnected)
        }
    }

    private func activate(_ source: AudioSourceType, reason: AudioSourceChangeReason) {
        activeSourceType = source
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
        do {
            let stream = try await phoneMic.start()
            // A concurrent stop()/restart may have run to completion while `phoneMic.start()`
            // was suspended above (RACE A — see the concurrency notes above `handle(_:)`).
            // Undo the now-orphaned start rather than resuming as if nothing happened.
            guard generation == gen, started else {
                await phoneMic.stop()
                return
            }
            micPumpTask = Task { [weak self] in
                for await chunk in stream {
                    await self?.forward(chunk, from: .phoneMic)
                }
            }
            activate(.phoneMic, reason: reason)
        } catch {
            guard generation == gen, started else { return }
            activeSourceType = nil
            emit(AudioSourceChange(source: nil, reason: .captureUnavailable))
        }
    }
}

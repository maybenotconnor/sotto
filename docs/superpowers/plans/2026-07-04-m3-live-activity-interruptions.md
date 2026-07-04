# M3 — Live Activity + Interruption Handling Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement spec milestone M3: a Live Activity (lock screen + Dynamic Island) with an `AudioRecordingIntent` pause/resume button, full audio-interruption handling (`.began`/`.ended`, fallback notification, background-task wrapper), route-change tap rebuild, and media-services-reset recovery.

**Architecture:** A new `SottoWidgets` extension target renders the Live Activity; the shared files (`SottoActivityAttributes`, `ToggleListeningIntent`) are dependency-free — the intent posts a `NotificationCenter` message that the app observes, so the widget target never compiles the app's object graph. The pipeline gains an `interrupted` status and a mode-parameterized halt (`performHalt(.stop|.interrupt)`) factored from the battle-tested `performStop`, plus `resumeFromInterruption()`. Every Apple framework is behind a protocol seam (`LiveActivityControlling`, `NotificationScheduling`, `BackgroundTasking`) with fakes, so interruption logic is fully unit-tested with synthetic `AVAudioSession` notifications; only lock-screen taps and real phone calls remain device-manual (spec M0c).

**Tech Stack:** ActivityKit, WidgetKit, AppIntents (`AudioRecordingIntent`, iOS 18+), UserNotifications, AVAudioSession notifications, Swift 6 strict concurrency, Swift Testing, XcodeGen.

## Global Constraints

- Test command (every task): `xcodebuild test -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone Air' 2>&1 | tail -5` → `** TEST SUCCEEDED **`. Slow, not hung. Simulator Busy → `xcrun simctl shutdown all`, retry.
- New files in EVERY task → run `xcodegen generate` before building.
- Zero Swift warnings (`grep "warning:" <log> | grep -v appintentsmetadataprocessor` → empty). NOTE: once the widget target exists, additional appintents tool notices may appear — same filter applies; only Swift-compiler warnings gate.
- Swift 6 language mode, `SWIFT_DEFAULT_ACTOR_ISOLATION: nonisolated` in BOTH targets.
- Spec (docs/SPEC.md "Live Activity", "Interruption handling") is binding: Live Activity runs whenever the app is not Idle; content = state label (Listening / Recording / Paused — call / Paused by you), elapsed time, today's conversation count, Pause/Resume button; on `.began` — background task wrapper, finalize-only (never transcribe inline — already true: recorder finalizes, transcription is M4), Live Activity → "Paused — call", **schedule the fallback notification on `.began`** (a matching `.ended` is NOT guaranteed), cancel it if resume happens first; on `.ended` — foreground: restart; background: do NOT call engine.start() (fails 561145187) — recovery only via intent/notification/app-open; route change `.oldDeviceUnavailable` → rebuild tap at new hardware format and continue; media services reset → full teardown/rebuild.
- Existing contracts that must survive: every pipeline transition contract (queued stops suspend until idle+drained+finalized; `.starting` truthfulness; deinit teardown; drain-before-finalize); recorder untouched except consumers of its existing `markInterrupted()`/`beginListening()`.
- M2-review carryovers to honor here: factor `performStop`'s skeleton (don't duplicate); `apply()` maps recorder `.interrupted` to a REAL `.interrupted` status now (not `.idle`); resume-after-`.began` must call a full `source.stop()` before `source.start()` (the source's `engine` field is non-nil after iOS killed the engine; `alreadyStarted` would throw otherwise); heartbeat: a graceful interruption records `.interrupted` — the unclean-shutdown banner logic already treats non-idle as unclean, which over-reports for interrupt-then-kill; ACCEPTED for M3 (spec's gap detection lands in M5), but `resumeFromInterruption()` and `performHalt(.stop)` record accurate states.
- API-verification rule (like M1's FluidAudio rule): the exact shapes of `AudioRecordingIntent`, `ActivityConfiguration`, and `Activity.request` must be verified against the installed SDK at execution time; if a signature differs from this plan, adapt minimally and record the deviation with the compiler error in the report — do not redesign.
- Git commit messages end with:

  Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>

## File Structure

```
project.yml                                     ← add SottoWidgets target (modify)
Sotto/LiveActivity/SottoActivityAttributes.swift ← shared: attributes (app + widget)
Sotto/LiveActivity/ToggleListeningIntent.swift   ← shared: intent + Notification.Name (app + widget)
Sotto/LiveActivity/LiveActivityControlling.swift ← protocol + ActivityKit controller (app only)
SottoWidgets/SottoWidgetsBundle.swift            ← @main WidgetBundle + Live Activity UI
Sotto/Notifications/NotificationScheduling.swift ← protocol + UNUserNotificationCenter impl
Sotto/Audio/AudioSessionObserver.swift           ← NotificationCenter observer + BackgroundTasking seam
Sotto/Audio/PhoneMicAudioSource.swift            ← rebuildTap() for route changes (modify)
Sotto/Pipeline/ListeningPipeline.swift           ← interrupted status, performHalt, resume (modify)
Sotto/App/ContentView.swift                      ← wiring: observer, controller, intent toggle (modify)
SottoTests/LiveActivityWiringTests.swift, InterruptionTests.swift, AudioSessionObserverTests.swift (new)
SottoTests/Fakes.swift, ListeningPipelineTests.swift (modify)
```

---

### Task 1: SottoWidgets extension target + shared attributes + Live Activity UI

**Files:**
- Modify: `project.yml`
- Create: `Sotto/LiveActivity/SottoActivityAttributes.swift`
- Create: `Sotto/LiveActivity/ToggleListeningIntent.swift`
- Create: `SottoWidgets/SottoWidgetsBundle.swift`
- Test: `SottoTests/LiveActivityWiringTests.swift` (attributes round-trip only, in this task)

**Interfaces:**
- Consumes: nothing new.
- Produces (later tasks rely on): `SottoActivityAttributes` with `ContentState { stateLabel: String; conversationCount: Int; isPaused: Bool }` and `let startedAt: Date`; `ToggleListeningIntent` (an `AudioRecordingIntent`) that posts `Notification.Name.sottoToggleListening` on `NotificationCenter.default` when performed; the `SottoWidgets` target embedded in the app.

- [ ] **Step 1: Add the widget target to `project.yml`**

Add to `targets:` (sibling of `Sotto`/`SottoTests`):

```yaml
  SottoWidgets:
    type: app-extension
    platform: iOS
    sources:
      - path: SottoWidgets
      - path: Sotto/LiveActivity/SottoActivityAttributes.swift
      - path: Sotto/LiveActivity/ToggleListeningIntent.swift
    settings:
      base:
        SWIFT_VERSION: "6.0"
        SWIFT_DEFAULT_ACTOR_ISOLATION: nonisolated
        PRODUCT_BUNDLE_IDENTIFIER: com.decanlys.Sotto.SottoWidgets   # extension IDs must be parent-prefixed or install fails
    info:
      path: SottoWidgets/Info.plist
      properties:
        CFBundleDisplayName: Sotto
        NSExtension:
          NSExtensionPointIdentifier: com.apple.widgetkit-extension
```

and to the `Sotto` app target's `dependencies:` add:

```yaml
      - target: SottoWidgets
        embed: true
```

- [ ] **Step 2: Create `Sotto/LiveActivity/SottoActivityAttributes.swift`** (compiled into BOTH targets)

```swift
import ActivityKit
import Foundation

/// Shared between the app (starts/updates the activity) and SottoWidgets (renders it).
/// Keep this file dependency-free — the widget target compiles it.
struct SottoActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var stateLabel: String        // "Listening" / "Recording" / "Paused — call" / "Paused by you"
        var conversationCount: Int
        var isPaused: Bool
    }

    /// Session start, for the elapsed-time timer on the lock screen.
    let startedAt: Date
}
```

- [ ] **Step 3: Create `Sotto/LiveActivity/ToggleListeningIntent.swift`** (compiled into BOTH targets)

```swift
import AppIntents
import Foundation

extension Notification.Name {
    /// Posted by ToggleListeningIntent.perform() — the app observes this and toggles the
    /// pipeline. Indirection keeps this file dependency-free for the widget target.
    static let sottoToggleListening = Notification.Name("sottoToggleListening")
}

/// AudioRecordingIntent (iOS 18+) is Apple's sanctioned mechanism for starting/stopping
/// recording from a Live Activity — the ONLY reliable way to restart the mic without
/// foregrounding the app (SPEC "Live Activity" job 1). The system runs perform() in the
/// APP process (launching it in the background if needed).
struct ToggleListeningIntent: AudioRecordingIntent {
    static let title: LocalizedStringResource = "Pause or resume listening"

    func perform() async throws -> some IntentResult {
        // Post on the MainActor: AppIntent.perform() carries no thread guarantee, and the
        // app-side .onReceive consumer mutates SwiftUI state.
        await MainActor.run {
            NotificationCenter.default.post(name: .sottoToggleListening, object: nil)
        }
        return .result()
    }
}
```

- [ ] **Step 4: Create `SottoWidgets/SottoWidgetsBundle.swift`**

```swift
import ActivityKit
import SwiftUI
import WidgetKit

@main
struct SottoWidgetsBundle: WidgetBundle {
    var body: some Widget {
        SottoLiveActivityWidget()
    }
}

/// SPEC "Live Activity": state label, elapsed listening time, today's conversation count,
/// Pause/Resume button. Compact Dynamic Island: state glyph + count.
struct SottoLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SottoActivityAttributes.self) { context in
            HStack(spacing: 12) {
                Image(systemName: context.state.isPaused ? "pause.circle.fill" : "waveform.circle.fill")
                    .font(.title2)
                    .foregroundStyle(context.state.isPaused ? .orange : .green)
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.state.stateLabel).font(.headline)
                    HStack(spacing: 6) {
                        Text(context.attributes.startedAt, style: .timer)
                        Text("· \(context.state.conversationCount) conversations")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Button(intent: ToggleListeningIntent()) {
                    Text(context.state.isPaused ? "Resume" : "Pause")
                        .font(.callout.bold())
                }
                .buttonStyle(.borderedProminent)
                .tint(context.state.isPaused ? .green : .orange)
            }
            .padding()
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: context.state.isPaused ? "pause.circle.fill" : "waveform.circle.fill")
                        .foregroundStyle(context.state.isPaused ? .orange : .green)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.stateLabel).font(.headline)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("\(context.state.conversationCount)").font(.headline)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Button(intent: ToggleListeningIntent()) {
                        Text(context.state.isPaused ? "Resume" : "Pause")
                    }
                    .buttonStyle(.borderedProminent)
                }
            } compactLeading: {
                Image(systemName: context.state.isPaused ? "pause.fill" : "waveform")
            } compactTrailing: {
                Text("\(context.state.conversationCount)")
            } minimal: {
                Image(systemName: context.state.isPaused ? "pause.fill" : "waveform")
            }
        }
    }
}
```

- [ ] **Step 5: Add the attributes round-trip test — `SottoTests/LiveActivityWiringTests.swift`**

```swift
import Foundation
import Testing
@testable import Sotto

struct LiveActivityWiringTests {
    @Test func contentStateRoundTripsThroughCodable() throws {
        let state = SottoActivityAttributes.ContentState(
            stateLabel: "Recording", conversationCount: 3, isPaused: false)
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(SottoActivityAttributes.ContentState.self, from: data)
        #expect(decoded == state)
    }
}
```

- [ ] **Step 6: `xcodegen generate`, build BOTH targets, run tests**

Run: `xcodebuild -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone Air' build 2>&1 | tail -3` then the standard test command.
Expected: build succeeds (widget compiles + embeds), `** TEST SUCCEEDED **`. If `AudioRecordingIntent` doesn't exist under that name in the SDK, check `xcrun --show-sdk-path` + grep the AppIntents swiftinterface for `RecordingIntent`, adapt to the actual protocol name, and record the deviation.

- [ ] **Step 7: Commit**

```bash
git add project.yml Sotto/LiveActivity SottoWidgets SottoTests/LiveActivityWiringTests.swift
git commit -m "feat: SottoWidgets Live Activity with AudioRecordingIntent pause/resume button"
```

---

### Task 2: LiveActivityControlling seam + ActivityKit controller

**Files:**
- Create: `Sotto/LiveActivity/LiveActivityControlling.swift`
- Modify: `SottoTests/Fakes.swift` (add `FakeLiveActivityController`)
- Test: `SottoTests/LiveActivityWiringTests.swift` (extend)

**Interfaces:**
- Consumes: `SottoActivityAttributes` (Task 1).
- Produces (Task 3 wires the pipeline to this):

```swift
@MainActor
protocol LiveActivityControlling: AnyObject {
    func sessionStarted(at date: Date)
    func update(stateLabel: String, conversationCount: Int, isPaused: Bool)
    func sessionEnded()
}
```

- [ ] **Step 1: Create `Sotto/LiveActivity/LiveActivityControlling.swift`**

```swift
import ActivityKit
import Foundation

/// Seam over ActivityKit so pipeline wiring is unit-testable. SPEC "Live Activity": the
/// activity runs whenever the app is not Idle and is ended on Stop.
@MainActor
protocol LiveActivityControlling: AnyObject {
    func sessionStarted(at date: Date)
    func update(stateLabel: String, conversationCount: Int, isPaused: Bool)
    func sessionEnded()
}

@MainActor
final class SottoLiveActivityController: LiveActivityControlling {
    private var activity: Activity<SottoActivityAttributes>?

    func sessionStarted(at date: Date) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let content = ActivityContent(
            state: SottoActivityAttributes.ContentState(
                stateLabel: "Listening", conversationCount: 0, isPaused: false),
            staleDate: nil)
        activity = try? Activity.request(
            attributes: SottoActivityAttributes(startedAt: date), content: content)
    }

    func update(stateLabel: String, conversationCount: Int, isPaused: Bool) {
        guard let activity else { return }
        let content = ActivityContent(
            state: SottoActivityAttributes.ContentState(
                stateLabel: stateLabel, conversationCount: conversationCount, isPaused: isPaused),
            staleDate: nil)
        Task { await activity.update(content) }
    }

    func sessionEnded() {
        guard let activity else { return }
        self.activity = nil
        let content = ActivityContent(
            state: SottoActivityAttributes.ContentState(
                stateLabel: "Stopped", conversationCount: 0, isPaused: true),
            staleDate: nil)
        Task { await activity.end(content, dismissalPolicy: .immediate) }
    }
}
```

- [ ] **Step 2: Add `FakeLiveActivityController` to `SottoTests/Fakes.swift`**

```swift
@MainActor
final class FakeLiveActivityController: LiveActivityControlling {
    private(set) var startedCount = 0
    private(set) var endedCount = 0
    private(set) var updates: [(label: String, count: Int, paused: Bool)] = []

    func sessionStarted(at date: Date) { startedCount += 1 }
    func update(stateLabel: String, conversationCount: Int, isPaused: Bool) {
        updates.append((stateLabel, conversationCount, isPaused))
    }
    func sessionEnded() { endedCount += 1 }
}
```

- [ ] **Step 3: Build + full suite green, commit**

```bash
git add Sotto/LiveActivity/LiveActivityControlling.swift SottoTests/Fakes.swift
git commit -m "feat: LiveActivityControlling seam over ActivityKit"
```

(No behavior to test yet beyond compilation — the pipeline wiring tests land in Task 3.)

---

### Task 3: Pipeline interruption surface (`interrupted` status, `performHalt`, resume) + Live Activity wiring

**Files:**
- Modify: `Sotto/Pipeline/ListeningPipeline.swift`
- Modify: `SottoTests/Fakes.swift` (extend `FakeRecorder` with `markInterruptedCount` and interrupted snapshot)
- Test: `SottoTests/InterruptionTests.swift` (new) + `SottoTests/ListeningPipelineTests.swift` (Live Activity assertions)

**Interfaces:**
- Consumes: `LiveActivityControlling` + fake (Task 2), `SegmentRecording.markInterrupted()` (M2), everything already in the pipeline.
- Produces (Tasks 4–6 rely on):
  - `ListeningPipeline.Status` gains `.interrupted`.
  - `init(source:recorder:heartbeat:liveActivity:)` — new optional `liveActivity: (any LiveActivityControlling)? = nil` parameter.
  - `func interrupt() async` — halt with `.interrupt` mode: stop source, drain, `recorder.markInterrupted()`, status `.interrupted`, heartbeat `.interrupted`, Live Activity "Paused — call". If a transition is in flight, records a pending interrupt honored when it completes (a queued STOP wins over a pending interrupt).
  - `func resumeFromInterruption() async` — only from `.interrupted`: full `source.stop()` first (clears the source's dead-engine state — `alreadyStarted` guard), then the normal start path; back to `.interrupted` on failure.
  - `func toggleFromIntent() async` — idle→start, interrupted→resume, else→stop (the intent/notification entry point).
  - Live Activity calls: `sessionStarted` on successful start, `update` on every status change (label mapping below), `sessionEnded` in `performHalt(.stop)`.
  - Status→label mapping (used for both Live Activity and later UI): idle→"Stopped", starting→"Starting…", listening→"Listening", recording→"Recording", silence→"Listening", interrupted→"Paused — call"; `isPaused` = (status == .interrupted).

- [ ] **Step 1: Extend `FakeRecorder` in `SottoTests/Fakes.swift`**

Add to `FakeRecorder`:

```swift
    private(set) var markInterruptedCount = 0
```

and make its `markInterrupted()` record and return properly:

```swift
    func markInterrupted() -> RecorderSnapshot {
        markInterruptedCount += 1
        finished = true
        return RecorderSnapshot(state: .interrupted, finalizedCount: 0, lastEvent: "Interrupted")
    }
```

(If the current fake's `markInterrupted` differs, replace it with exactly this.)

- [ ] **Step 2: Write the failing tests — `SottoTests/InterruptionTests.swift`**

```swift
import Testing
@testable import Sotto

@MainActor
struct InterruptionTests {
    @Test func interruptHaltsAndParks() async throws {
        let source = FakeAudioSource()
        let recorder = FakeRecorder()
        let activity = FakeLiveActivityController()
        let pipeline = ListeningPipeline(
            source: source, recorder: recorder, liveActivity: activity)

        await pipeline.start()
        await source.emitSilentChunks(count: 2)
        await pipeline.interrupt()

        #expect(pipeline.status == .interrupted)
        #expect(await recorder.markInterruptedCount == 1)
        #expect(await recorder.processedAfterFinish == 0)      // drained before parking
        #expect(await source.stopCallCount == 1)               // engine torn down
        #expect(activity.updates.last?.label == "Paused — call")
        #expect(activity.updates.last?.paused == true)
        #expect(activity.endedCount == 0)                      // activity survives interruption
    }

    @Test func interruptWhenIdleIsNoOp() async throws {
        let recorder = FakeRecorder()
        let pipeline = ListeningPipeline(
            source: FakeAudioSource(), recorder: recorder, liveActivity: nil)
        await pipeline.interrupt()
        #expect(pipeline.status == .idle)
        #expect(await recorder.markInterruptedCount == 0)
    }

    @Test func resumeFromInterruptionRestartsCleanly() async throws {
        let source = FakeAudioSource()
        let recorder = FakeRecorder()
        let activity = FakeLiveActivityController()
        let pipeline = ListeningPipeline(
            source: source, recorder: recorder, liveActivity: activity)

        await pipeline.start()
        await pipeline.interrupt()
        await pipeline.resumeFromInterruption()

        #expect(pipeline.status == .listening)
        #expect(await source.startCallCount == 2)
        #expect(await source.stopCallCount >= 2)               // defensive stop before restart
        #expect(await recorder.beginCount == 2)
        #expect(activity.updates.last?.paused == false)
    }

    @Test func resumeWhenNotInterruptedIsNoOp() async throws {
        let source = FakeAudioSource()
        let pipeline = ListeningPipeline(
            source: source, recorder: FakeRecorder(), liveActivity: nil)
        await pipeline.start()
        await pipeline.resumeFromInterruption()                // listening, not interrupted
        #expect(pipeline.status == .listening)
        #expect(await source.startCallCount == 1)
        await pipeline.stop()
    }

    @Test func stopFromInterruptedGoesIdleAndEndsActivity() async throws {
        let source = FakeAudioSource()
        let activity = FakeLiveActivityController()
        let pipeline = ListeningPipeline(
            source: source, recorder: FakeRecorder(), liveActivity: activity)

        await pipeline.start()
        await pipeline.interrupt()
        await pipeline.stop()

        #expect(pipeline.status == .idle)
        #expect(activity.endedCount == 1)
    }

    @Test func interruptDuringStartIsHonoredAfterStartCompletes() async throws {
        let source = SlowStartAudioSource()
        let recorder = FakeRecorder()
        let pipeline = ListeningPipeline(
            source: source, recorder: recorder, liveActivity: nil)

        async let starting: Void = pipeline.start()
        await source.waitUntilStartRequested()
        await pipeline.interrupt()                             // mid-start: pends, returns
        await source.releaseStart()
        await starting

        #expect(pipeline.status == .interrupted)
        #expect(await recorder.markInterruptedCount == 1)
    }

    @Test func queuedStopBeatsPendingInterrupt() async throws {
        let source = SlowStartAudioSource()
        let recorder = FakeRecorder()
        let pipeline = ListeningPipeline(
            source: source, recorder: recorder, liveActivity: nil)

        async let starting: Void = pipeline.start()
        await source.waitUntilStartRequested()
        await pipeline.interrupt()                             // pends
        async let stopping: Void = pipeline.stop()             // queues (stop wins)
        for _ in 0..<5 { await Task.yield() }
        await source.releaseStart()
        _ = await (starting, stopping)

        #expect(pipeline.status == .idle)                      // stop won
        #expect(await recorder.finishCount == 1)
        #expect(await recorder.markInterruptedCount == 0)
    }

    @Test func toggleFromIntentCoversAllThreeStates() async throws {
        let source = FakeAudioSource()
        let pipeline = ListeningPipeline(
            source: source, recorder: FakeRecorder(), liveActivity: nil)

        await pipeline.toggleFromIntent()                      // idle → start
        #expect(pipeline.status == .listening)
        await pipeline.interrupt()
        await pipeline.toggleFromIntent()                      // interrupted → resume
        #expect(pipeline.status == .listening)
        await pipeline.toggleFromIntent()                      // active → stop
        #expect(pipeline.status == .idle)
    }
}
```

Also append to `SottoTests/ListeningPipelineTests.swift`:

```swift
    @Test func liveActivityFollowsSessionLifecycle() async throws {
        let source = FakeAudioSource()
        let activity = FakeLiveActivityController()
        let pipeline = ListeningPipeline(
            source: source, recorder: FakeRecorder(stateScript: [1: .recording]),
            liveActivity: activity)

        await pipeline.start()
        #expect(activity.startedCount == 1)
        await source.emitSilentChunks(count: 2)
        await source.finish()
        await pipeline.waitUntilDrained()
        #expect(activity.updates.contains { $0.label == "Recording" })
        await pipeline.stop()
        #expect(activity.endedCount == 1)
    }
```

- [ ] **Step 3: `xcodegen generate`, verify RED** (no `.interrupted` case, no `liveActivity:` parameter, etc.)

- [ ] **Step 4: Implement in `Sotto/Pipeline/ListeningPipeline.swift`**

Deltas from the current file (apply all; everything else unchanged):

1. `Status` gains `case interrupted`.
2. New stored properties + init parameter:

```swift
    private let liveActivity: (any LiveActivityControlling)?
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
```

3. `start()`: after the successful-start block (`pumpTask = ...`), add `liveActivity?.sessionStarted(at: Date())`. Replace the post-transition queued-stop block with:

```swift
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
```

4. Rename `performStop()` to `performHalt(_ mode: HaltMode)` with:

```swift
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
        // is meaningless and must not leak into a future session. (Review-found fix:
        // without this, a stop queued during an interrupt-halt was swallowed, and a
        // stale pendingInterrupt could hijack the next start.)
        if !queuedStops.isEmpty && status != .idle {
            pendingInterrupt = false
            await performHalt(.stop)   // bounded recursion: the inner halt ends at .idle
            return                     // the inner call resumed the waiters
        }
        pendingInterrupt = false
        resumeQueuedStops()
    }
```

and `stop()`'s body calls `await performHalt(.stop)` (its guard/queue logic unchanged).

5. New methods:

```swift
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
```

6. `apply(_:)`: map `.interrupted` to the new status and push Live Activity updates on every status change:

```swift
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
```

7. `ContentView`'s `PipelineView` switches gain `.interrupted` → label "Paused — call", color `.orange`; the button during `.interrupted` should read "Resume" and call `resumeFromInterruption()`:

```swift
            Button(buttonLabel) {
                Task {
                    switch pipeline.status {
                    case .idle: await pipeline.start()
                    case .interrupted: await pipeline.resumeFromInterruption()
                    default: await pipeline.stop()
                    }
                }
            }
```

with `buttonLabel`: idle→"Start Listening", interrupted→"Resume", else "Stop".

- [ ] **Step 5: Full suite green** (existing pipeline tests must be untouched-green; ~9 new tests). Commit:

```bash
git add Sotto/Pipeline/ListeningPipeline.swift Sotto/App/ContentView.swift SottoTests/Fakes.swift SottoTests/InterruptionTests.swift SottoTests/ListeningPipelineTests.swift
git commit -m "feat: interrupted status, performHalt modes, resume path, Live Activity wiring"
```

---

### Task 4: NotificationScheduling seam (fallback notification) + provisional authorization

**Files:**
- Create: `Sotto/Notifications/NotificationScheduling.swift`
- Modify: `Sotto/Pipeline/ListeningPipeline.swift` (schedule on interrupt, cancel on resume/stop)
- Modify: `SottoTests/Fakes.swift` (`FakeNotificationScheduler`)
- Test: `SottoTests/InterruptionTests.swift` (extend)

**Interfaces:**
- Consumes: pipeline from Task 3.
- Produces: `protocol NotificationScheduling: Sendable { func requestAuthorizationIfNeeded() async; func schedulePausedNotification() async; func cancelPausedNotification() async }`; `UserNotificationScheduler` (UNUserNotificationCenter, `.provisional` auth); pipeline `init` gains `notifications: (any NotificationScheduling)? = nil`.

- [ ] **Step 1: Create `Sotto/Notifications/NotificationScheduling.swift`**

```swift
import Foundation
import UserNotifications

/// SPEC "Interruption handling": the fallback notification is scheduled on `.began` — a
/// matching `.ended` is NOT guaranteed — and cancelled if resume happens first.
protocol NotificationScheduling: Sendable {
    func requestAuthorizationIfNeeded() async
    func schedulePausedNotification() async
    func cancelPausedNotification() async
}

struct UserNotificationScheduler: NotificationScheduling {
    private static let pausedIdentifier = "sotto.paused"

    func requestAuthorizationIfNeeded() async {
        // Provisional: delivered quietly, no permission prompt (SPEC onboarding defers the
        // full prompt decision to M6; provisional keeps the fallback path working today).
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .provisional])
    }

    func schedulePausedNotification() async {
        let content = UNMutableNotificationContent()
        content.title = "Sotto was paused"
        content.body = "Listening stopped for a call or Siri. Tap to resume."
        let request = UNNotificationRequest(
            identifier: Self.pausedIdentifier, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    func cancelPausedNotification() async {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.pausedIdentifier])
        center.removeDeliveredNotifications(withIdentifiers: [Self.pausedIdentifier])
    }
}
```

- [ ] **Step 2: `FakeNotificationScheduler` in Fakes.swift**

```swift
actor FakeNotificationScheduler: NotificationScheduling {
    private(set) var authorizationRequests = 0
    private(set) var scheduled = 0
    private(set) var cancelled = 0
    func requestAuthorizationIfNeeded() { authorizationRequests += 1 }
    func schedulePausedNotification() { scheduled += 1 }
    func cancelPausedNotification() { cancelled += 1 }
}
```

- [ ] **Step 3: Wire into the pipeline**

- `init` gains `notifications: (any NotificationScheduling)? = nil` (stored).
- `start()`: on first successful start, `await notifications?.requestAuthorizationIfNeeded()` (after the pump is created; ordering vs. UI irrelevant).
- `performHalt(.interrupt)`: after the recorder call, `await notifications?.schedulePausedNotification()`.
- `resumeFromInterruption()` success path and `performHalt(.stop)`: `await notifications?.cancelPausedNotification()`.

- [ ] **Step 4: Tests (extend InterruptionTests)**

```swift
    @Test func interruptSchedulesFallbackNotificationAndResumeCancelsIt() async throws {
        let source = FakeAudioSource()
        let notifications = FakeNotificationScheduler()
        let pipeline = ListeningPipeline(
            source: source, recorder: FakeRecorder(),
            liveActivity: nil, notifications: notifications)

        await pipeline.start()
        #expect(await notifications.authorizationRequests == 1)
        await pipeline.interrupt()
        #expect(await notifications.scheduled == 1)            // scheduled on .began, per spec
        await pipeline.resumeFromInterruption()
        #expect(await notifications.cancelled == 1)
    }
```

- [ ] **Step 5: Full suite green, commit**

```bash
git add Sotto/Notifications SottoTests/Fakes.swift SottoTests/InterruptionTests.swift Sotto/Pipeline/ListeningPipeline.swift
git commit -m "feat: fallback paused-notification seam scheduled on interruption began"
```

---

### Task 5: AudioSessionObserver + background-task seam + route/media-reset handling

**Files:**
- Create: `Sotto/Audio/AudioSessionObserver.swift`
- Modify: `Sotto/Audio/PhoneMicAudioSource.swift` (add `rebuildTap()`)
- Modify: `Sotto/App/ContentView.swift` (instantiate observer + full wiring incl. intent notification)
- Test: `SottoTests/AudioSessionObserverTests.swift`

**Interfaces:**
- Consumes: pipeline surface from Tasks 3–4.
- Produces:

```swift
/// Wraps UIApplication background-task begin/end so interruption handling is testable.
protocol BackgroundTasking: Sendable {
    func begin() -> Int          // opaque task id (-1 == invalid/none)
    func end(_ identifier: Int)
}

@MainActor
final class AudioSessionObserver {
    init(center: NotificationCenter = .default, backgroundTasks: any BackgroundTasking)
    var onInterruptionBegan: (() async -> Void)?
    var onInterruptionEndedShouldResume: ((Bool) async -> Void)?  // arg: .shouldResume option
    var onRouteChangeDeviceUnavailable: (() async -> Void)?
    var onMediaServicesReset: (() async -> Void)?
    func startObserving(session: AVAudioSession = .sharedInstance())
}

// PhoneMicAudioSource gains:
// func rebuildTap() async throws  — remove tap, re-read hardware format, new converter, reinstall
//                                   on the SAME continuation; engine keeps running.
```

- [ ] **Step 1: Write the failing tests — `SottoTests/AudioSessionObserverTests.swift`**

```swift
import AVFoundation
import Foundation
import Testing
@testable import Sotto

@MainActor
struct AudioSessionObserverTests {
    final class FakeBackgroundTasks: BackgroundTasking, @unchecked Sendable {
        // Mutated only on the MainActor in these tests.
        private(set) var begun = 0
        private(set) var ended: [Int] = []
        func begin() -> Int { begun += 1; return begun }
        func end(_ identifier: Int) { ended.append(identifier) }
    }

    private func makeObserver() -> (AudioSessionObserver, NotificationCenter, FakeBackgroundTasks) {
        let center = NotificationCenter()
        let tasks = FakeBackgroundTasks()
        let observer = AudioSessionObserver(center: center, backgroundTasks: tasks)
        return (observer, center, tasks)
    }

    @Test func interruptionBeganFiresCallbackInsideBackgroundTask() async throws {
        let (observer, center, tasks) = makeObserver()
        var beganCalls = 0
        observer.onInterruptionBegan = { beganCalls += 1 }
        observer.startObserving(session: AVAudioSession.sharedInstance())

        center.post(
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            userInfo: [AVAudioSessionInterruptionTypeKey:
                AVAudioSession.InterruptionType.began.rawValue])
        try await Task.sleep(for: .milliseconds(100))   // handler hops through a Task

        #expect(beganCalls == 1)
        #expect(tasks.begun == 1)
        #expect(tasks.ended == [1])                     // task ended after the handler finished
    }

    @Test func interruptionEndedForwardsShouldResume() async throws {
        let (observer, center, _) = makeObserver()
        var received: [Bool] = []
        observer.onInterruptionEndedShouldResume = { received.append($0) }
        observer.startObserving(session: AVAudioSession.sharedInstance())

        center.post(
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            userInfo: [
                AVAudioSessionInterruptionTypeKey:
                    AVAudioSession.InterruptionType.ended.rawValue,
                AVAudioSessionInterruptionOptionKey:
                    AVAudioSession.InterruptionOptions.shouldResume.rawValue,
            ])
        try await Task.sleep(for: .milliseconds(100))

        #expect(received == [true])
    }

    @Test func oldDeviceUnavailableRouteChangeFires() async throws {
        let (observer, center, _) = makeObserver()
        var calls = 0
        observer.onRouteChangeDeviceUnavailable = { calls += 1 }
        observer.startObserving(session: AVAudioSession.sharedInstance())

        center.post(
            name: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            userInfo: [AVAudioSessionRouteChangeReasonKey:
                AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue])
        try await Task.sleep(for: .milliseconds(100))
        #expect(calls == 1)

        // Other reasons are ignored:
        center.post(
            name: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            userInfo: [AVAudioSessionRouteChangeReasonKey:
                AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue])
        try await Task.sleep(for: .milliseconds(100))
        #expect(calls == 1)
    }

    @Test func mediaServicesResetFires() async throws {
        let (observer, center, _) = makeObserver()
        var calls = 0
        observer.onMediaServicesReset = { calls += 1 }
        observer.startObserving(session: AVAudioSession.sharedInstance())

        center.post(
            name: AVAudioSession.mediaServicesWereResetNotification,
            object: AVAudioSession.sharedInstance())
        try await Task.sleep(for: .milliseconds(100))
        #expect(calls == 1)
    }
}
```

- [ ] **Step 2: `xcodegen generate`, verify RED**

- [ ] **Step 3: Create `Sotto/Audio/AudioSessionObserver.swift`**

```swift
import AVFoundation
import Foundation
import UIKit

/// Wraps UIApplication background-task begin/end (SPEC: after audio stops, ~30 s before
/// suspension — wrap the `.began` handler in a background task).
protocol BackgroundTasking: Sendable {
    func begin() -> Int
    func end(_ identifier: Int)
}

struct UIKitBackgroundTasks: BackgroundTasking {
    func begin() -> Int {
        // Runs on any thread; UIApplication.beginBackgroundTask is documented main-thread-safe.
        UIApplication.shared.beginBackgroundTask(withName: "sotto.interruption").rawValue
    }

    func end(_ identifier: Int) {
        UIApplication.shared.endBackgroundTask(UIBackgroundTaskIdentifier(rawValue: identifier))
    }
}

/// Registers for the three session notifications (SPEC "Interruption handling") and
/// forwards them as async callbacks. Owns no policy — the pipeline decides what to do.
@MainActor
final class AudioSessionObserver {
    private let center: NotificationCenter
    private let backgroundTasks: any BackgroundTasking
    private var tokens: [NSObjectProtocol] = []

    var onInterruptionBegan: (() async -> Void)?
    var onInterruptionEndedShouldResume: ((Bool) async -> Void)?
    var onRouteChangeDeviceUnavailable: (() async -> Void)?
    var onMediaServicesReset: (() async -> Void)?

    init(center: NotificationCenter = .default, backgroundTasks: any BackgroundTasking) {
        self.center = center
        self.backgroundTasks = backgroundTasks
    }

    func startObserving(session: AVAudioSession = .sharedInstance()) {
        tokens.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: session, queue: .main
        ) { [weak self] notification in
            guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            let shouldResume: Bool = {
                guard let optionsRaw =
                    notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
                else { return false }
                return AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
                    .contains(.shouldResume)
            }()
            MainActor.assumeIsolated {
                guard let self else { return }
                switch type {
                case .began:
                    let taskID = self.backgroundTasks.begin()
                    let handler = self.onInterruptionBegan
                    let tasks = self.backgroundTasks
                    Task {
                        await handler?()
                        tasks.end(taskID)
                    }
                case .ended:
                    let handler = self.onInterruptionEndedShouldResume
                    Task { await handler?(shouldResume) }
                @unknown default:
                    break
                }
            }
        })

        tokens.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: session, queue: .main
        ) { [weak self] notification in
            guard let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: raw),
                  reason == .oldDeviceUnavailable else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                let handler = self.onRouteChangeDeviceUnavailable
                Task { await handler?() }
            }
        })

        tokens.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let handler = self.onMediaServicesReset
                Task { await handler?() }
            }
        })
    }

    deinit {
        for token in tokens {
            center.removeObserver(token)
        }
    }
}
```

NOTE for the implementer: the `queue: .main` + `MainActor.assumeIsolated` pattern is the Swift 6 way to bridge NotificationCenter block observers onto the MainActor without a hop; if the compiler rejects capture semantics here, an acceptable fallback is capturing the handlers into local `let`s before `MainActor.assumeIsolated` — record whatever adaptation was needed.

- [ ] **Step 4: Add `rebuildTap()` to `Sotto/Audio/PhoneMicAudioSource.swift`**

```swift
    /// Route change (.oldDeviceUnavailable): the hardware format may have changed (SPEC —
    /// e.g. wired mic unplugged). Rebuild converter + tap on the SAME stream; engine keeps
    /// running. No-op when not capturing.
    func rebuildTap() throws {
        guard let engine, let continuation else { return }
        let input = engine.inputNode
        // Validate + build the replacement BEFORE removing the old tap: throwing after
        // removal would leave the engine running with no tap at all (silent capture loss).
        let hardwareFormat = input.outputFormat(forBus: 0)
        guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0,
              let converter = FormatConverter(inputFormat: hardwareFormat) else {
            throw AudioSourceError.invalidHardwareFormat
        }
        let processor = TapProcessor(converter: converter)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(VADConstants.chunkSize),
                         format: hardwareFormat) { buffer, when in
            processor.handle(buffer, hostTime: when.hostTime, continuation: continuation)
        }
    }
```

- [ ] **Step 5: Wire everything in `Sotto/App/ContentView.swift`**

In `setUp()`, after the pipeline is constructed, add (and add `@State private var observer: AudioSessionObserver?` plus keep a reference):

```swift
            let source = PhoneMicAudioSource()
            let newPipeline = ListeningPipeline(
                source: source, recorder: recorder, heartbeat: heartbeat,
                liveActivity: SottoLiveActivityController(),
                notifications: UserNotificationScheduler())
            pipeline = newPipeline

            let sessionObserver = AudioSessionObserver(backgroundTasks: UIKitBackgroundTasks())
            sessionObserver.onInterruptionBegan = { [weak newPipeline] in
                await newPipeline?.interrupt()
            }
            sessionObserver.onInterruptionEndedShouldResume = { [weak newPipeline] shouldResume in
                // Foregrounded + system says resume → restart. Backgrounded: engine.start()
                // fails (561145187); recovery stays with the intent/notification/app-open.
                guard shouldResume, UIApplication.shared.applicationState == .active else { return }
                await newPipeline?.resumeFromInterruption()
            }
            sessionObserver.onRouteChangeDeviceUnavailable = { [weak source, weak newPipeline] in
                do {
                    try await source?.rebuildTap()
                } catch {
                    // No valid input route: park honestly instead of silently losing capture.
                    await newPipeline?.interrupt()
                }
            }
            sessionObserver.onMediaServicesReset = { [weak newPipeline] in
                // Full teardown + rebuild (SPEC): park, then restart the whole stack.
                await newPipeline?.interrupt()
                // Backgrounded: engine.start() fails (561145187); recovery stays with the
                // intent/notification/app-open, and interrupt() already scheduled the fallback.
                guard UIApplication.shared.applicationState == .active else { return }
                await newPipeline?.resumeFromInterruption()
            }
            sessionObserver.startObserving()
            observer = sessionObserver
```

and add the intent-notification bridge on the outermost view (in `body`, on the `NavigationStack`):

```swift
        .onReceive(NotificationCenter.default.publisher(for: .sottoToggleListening)) { _ in
            Task { await pipeline?.toggleFromIntent() }
        }
```

(`import UIKit` where needed; `import Combine` for `.onReceive` is implicit via SwiftUI.)

- [ ] **Step 6: Full suite green** (4 new observer tests). Commit:

```bash
git add Sotto/Audio/AudioSessionObserver.swift Sotto/Audio/PhoneMicAudioSource.swift Sotto/App/ContentView.swift SottoTests/AudioSessionObserverTests.swift
git commit -m "feat: audio session observer with background task, route rebuild, media-reset recovery"
```

---

### Task 6: End-to-end simulator verification

**Files:** none new (verification only; screenshots to scratch).

- [ ] **Step 1: Build, install, launch on the iPhone Air simulator** (standard commands; grant mic). Screenshot: app shows Idle.
- [ ] **Step 2: Start listening via `xcrun simctl` launch + manual-equivalent check:** verify via `xcrun simctl spawn "iPhone Air" log stream --predicate 'subsystem CONTAINS "sotto" OR process == "Sotto"' --timeout 10` that no crash occurs on Start (the Live Activity request runs). Screenshot the app in Listening state if Start can be triggered (it cannot be tapped by an agent — report it as the human step).
- [ ] **Step 3: Report** which parts are verified (build, launch, tests) and which remain human/device steps: lock-screen Live Activity appearance, intent button tap, real phone-call interruption (spec M0c drill), route change with real hardware.

No commit (nothing changes). The milestone's final review follows separately.

## Self-review notes

- Spec M3 coverage: Live Activity content (state label, elapsed, count, pause/resume button) ✓ Task 1; `AudioRecordingIntent` ✓ Task 1 (in-app perform via notification bridge); activity lifecycle tied to non-Idle ✓ Task 3; `.began` flow (background task ✓ Task 5, finalize-fast ✓ recorder, activity → "Paused — call" ✓ Task 3, notification scheduled on `.began` ✓ Task 4, dedupe/cancel on resume ✓ Task 4); `.ended` foreground-only restart ✓ Task 5; route change rebuild ✓ Task 5; media-services reset ✓ Task 5; `UNUserNotificationCenter` authorization ✓ Task 4 (provisional; M6 revisits).
- Known deliberate scope cuts: no notification-tap deep-link handling (tapping the fallback notification just opens the app; the app-open path to resume is the button — spec lists app-open as the third recovery path, satisfied); heartbeat's interrupted-state unclean-shutdown over-report accepted until M5.
- Type consistency: `performHalt(.stop/.interrupt)` used consistently; `liveActivity`/`notifications` init parameter order (source, recorder, heartbeat, liveActivity, notifications) — all call sites in tests use labeled args so order is non-breaking; `FakeRecorder.markInterrupted` returns `.interrupted` snapshot consumed by `apply()`.

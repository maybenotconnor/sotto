# Live Activity Phase Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the Live Activity's string-based content state with a `Phase` enum so the Dynamic Island shows the VAD state (listening/recording/paused) and the unlabeled conversation count disappears from the Island (it stays, labeled, on the lock screen).

**Architecture:** `SottoActivityAttributes.ContentState` becomes `{phase, conversationCount}`; the pipeline maps its `Status` to a `Phase` (nil for idle/starting — no update pushed); the widget derives label/glyph/tint from `phase`. Spec: `docs/superpowers/specs/2026-07-06-live-activity-redesign-design.md`.

**Tech Stack:** Swift 6, ActivityKit, WidgetKit, Swift Testing (`@Test`/`#expect`), XcodeGen.

## Global Constraints

- Test command: `xcodebuild test -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone Air' 2>&1 | tail -5` → `** TEST SUCCEEDED **`
- New files → `xcodegen generate` first (this plan creates no new files).
- Zero Swift warnings (appintents exempt). `SWIFT_DEFAULT_ACTOR_ISOLATION: nonisolated`.
- `SottoActivityAttributes.swift` stays dependency-free — both app and widget targets compile it.

---

### Task 1: Phase-based Live Activity contract, wiring, and widget

One compile-atomic change: the contract, its two consumers (controller, widget), the pipeline mapping, and the tests. Intermediate steps won't compile until Step 7 — that's expected for a contract swap; "red" here is the compile failure of Step 1's rewritten test.

**Files:**
- Modify: `Sotto/LiveActivity/SottoActivityAttributes.swift` (full rewrite, shown)
- Modify: `Sotto/LiveActivity/LiveActivityControlling.swift`
- Modify: `Sotto/Pipeline/ListeningPipeline.swift:281-292, 314-323`
- Modify: `SottoWidgets/SottoWidgetsBundle.swift` (full rewrite, shown)
- Modify: `SottoTests/Fakes.swift:366-379`
- Test: `SottoTests/LiveActivityWiringTests.swift`, `SottoTests/InterruptionTests.swift`, `SottoTests/ListeningPipelineTests.swift`

**Interfaces:**
- Produces: `SottoActivityAttributes.Phase` (`.listening | .recording | .pausedByUser | .pausedBySystem`, `String` raw values, `var isPaused: Bool`); `LiveActivityControlling.update(phase:conversationCount:)`; `ListeningPipeline.activityPhase(for:) -> SottoActivityAttributes.Phase?`
- Consumes: existing `ListeningPipeline.Status`, `haltReason`, `ToggleListeningIntent` (all unchanged).

- [ ] **Step 1: Rewrite the wiring test against the new contract (red = compile failure)**

Replace the body of `SottoTests/LiveActivityWiringTests.swift` with:

```swift
import Foundation
import Testing
@testable import Sotto

struct LiveActivityWiringTests {
    @Test func contentStateRoundTripsThroughCodable() throws {
        let state = SottoActivityAttributes.ContentState(
            phase: .recording, conversationCount: 3)
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(SottoActivityAttributes.ContentState.self, from: data)
        #expect(decoded == state)
    }

    @Test func pausedPhasesReportPaused() {
        #expect(SottoActivityAttributes.Phase.pausedByUser.isPaused)
        #expect(SottoActivityAttributes.Phase.pausedBySystem.isPaused)
        #expect(!SottoActivityAttributes.Phase.listening.isPaused)
        #expect(!SottoActivityAttributes.Phase.recording.isPaused)
    }
}
```

- [ ] **Step 2: Verify red**

Run: `xcodebuild test -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone Air' -only-testing:SottoTests/LiveActivityWiringTests 2>&1 | tail -5`
Expected: BUILD FAILED (no member `phase` on ContentState).

- [ ] **Step 3: Rewrite the shared attributes**

Replace `Sotto/LiveActivity/SottoActivityAttributes.swift` entirely with:

```swift
import ActivityKit
import Foundation

/// Shared between the app (starts/updates the activity) and SottoWidgets (renders it).
/// Keep this file dependency-free — the widget target compiles it.
struct SottoActivityAttributes: ActivityAttributes {
    /// What the session is actually doing. The widget derives all visuals (glyph,
    /// tint, label) from this; raw-value Codable is the wire format across the
    /// app/widget process boundary — don't rename cases casually.
    enum Phase: String, Codable, Hashable {
        case listening, recording, pausedByUser, pausedBySystem

        var isPaused: Bool { self == .pausedByUser || self == .pausedBySystem }
    }

    struct ContentState: Codable, Hashable {
        var phase: Phase
        var conversationCount: Int
    }

    /// Session start, for the elapsed-time timer on the lock screen.
    let startedAt: Date
}
```

- [ ] **Step 4: Update the controller protocol and implementation**

In `Sotto/LiveActivity/LiveActivityControlling.swift`, replace the protocol method
`func update(stateLabel: String, conversationCount: Int, isPaused: Bool)` with:

```swift
    func update(phase: SottoActivityAttributes.Phase, conversationCount: Int)
```

Replace `SottoLiveActivityController.sessionStarted`, `.update`, and `.sessionEnded` with (leave `endAllStale()` and the class/property declarations untouched):

```swift
    func sessionStarted(at date: Date) {
        endAllStale()
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let content = ActivityContent(
            state: SottoActivityAttributes.ContentState(phase: .listening, conversationCount: 0),
            staleDate: nil)
        activity = try? Activity.request(
            attributes: SottoActivityAttributes(startedAt: date), content: content)
    }

    func update(phase: SottoActivityAttributes.Phase, conversationCount: Int) {
        guard let activity else { return }
        let content = ActivityContent(
            state: SottoActivityAttributes.ContentState(
                phase: phase, conversationCount: conversationCount),
            staleDate: nil)
        Task { await activity.update(content) }
    }

    func sessionEnded() {
        guard let activity else { return }
        self.activity = nil
        // Dismissal is immediate, so final content is never visible — end with none.
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }
```

- [ ] **Step 5: Update the pipeline mapping**

In `Sotto/Pipeline/ListeningPipeline.swift`, inside `apply(_:)` replace both `liveActivity?.update(...)` calls:

```swift
        if status != newStatus {
            status = newStatus
            heartbeat?.record(snapshot.state)
            if let phase = activityPhase(for: newStatus) {
                liveActivity?.update(phase: phase, conversationCount: snapshot.finalizedCount)
            }
        } else if finalizedCount != snapshot.finalizedCount {
            // Status-unchanged path: the branch above already pushed the fresh count when
            // status ALSO changed, so this only fires standalone — no double update.
            if let phase = activityPhase(for: status) {
                liveActivity?.update(phase: phase, conversationCount: snapshot.finalizedCount)
            }
        }
```

Replace `activityLabel(for:)` (lines 312-323, including its doc comment) with:

```swift
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
```

- [ ] **Step 6: Update the fake and the label-based test assertions**

`SottoTests/Fakes.swift` — replace `FakeLiveActivityController` with:

```swift
@MainActor
final class FakeLiveActivityController: LiveActivityControlling {
    private(set) var startedCount = 0
    private(set) var endedCount = 0
    private(set) var endAllStaleCount = 0
    private(set) var updates: [(phase: SottoActivityAttributes.Phase, count: Int)] = []

    func sessionStarted(at date: Date) { startedCount += 1 }
    func update(phase: SottoActivityAttributes.Phase, conversationCount: Int) {
        updates.append((phase, conversationCount))
    }
    func sessionEnded() { endedCount += 1 }
    func endAllStale() { endAllStaleCount += 1 }
}
```

`SottoTests/InterruptionTests.swift` — three assertion swaps:

In `interruptHaltsAndParks` replace:
```swift
        #expect(activity.updates.last?.label == "Paused — call")
        #expect(activity.updates.last?.paused == true)
```
with:
```swift
        #expect(activity.updates.last?.phase == .pausedBySystem)
```

In `resumeFromInterruptionRestartsCleanly` replace:
```swift
        #expect(activity.updates.last?.paused == false)
```
with:
```swift
        #expect(activity.updates.last?.phase == .listening)
```

In `pauseByUserParksWithoutFallbackNotification` replace:
```swift
        #expect(activity.updates.last?.label == "Paused by you")
```
with:
```swift
        #expect(activity.updates.last?.phase == .pausedByUser)
```

`SottoTests/ListeningPipelineTests.swift` — in `liveActivityFollowsSessionLifecycle` replace:
```swift
        #expect(activity.updates.contains { $0.label == "Recording" })
```
with:
```swift
        #expect(activity.updates.contains { $0.phase == .recording })
```

- [ ] **Step 7: Rewrite the widget**

Replace `SottoWidgets/SottoWidgetsBundle.swift` entirely with:

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

extension SottoActivityAttributes.Phase {
    var label: String {
        switch self {
        case .listening: "Listening"
        case .recording: "Recording"
        case .pausedByUser: "Paused by you"
        case .pausedBySystem: "Paused — call"
        }
    }

    var tint: Color {
        switch self {
        case .listening: .green
        case .recording: .red
        case .pausedByUser, .pausedBySystem: .orange
        }
    }

    /// Lock screen and expanded Island.
    var glyph: String {
        switch self {
        case .listening: "waveform"
        case .recording: "record.circle.fill"
        case .pausedByUser, .pausedBySystem: "pause.circle.fill"
        }
    }

    /// Compact and minimal Island slots want the unadorned forms.
    var compactGlyph: String {
        switch self {
        case .listening: "waveform"
        case .recording: "record.circle.fill"
        case .pausedByUser, .pausedBySystem: "pause.fill"
        }
    }
}

/// SPEC "Live Activity": lock screen = state label, elapsed timer, labeled conversation
/// count, Pause/Resume button. Dynamic Island compact/minimal = VAD-state glyph only
/// (no count); expanded = glyph, label, elapsed timer, Pause/Resume.
struct SottoLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SottoActivityAttributes.self) { context in
            HStack(spacing: 12) {
                Image(systemName: context.state.phase.glyph)
                    .font(.title2)
                    .foregroundStyle(context.state.phase.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.state.phase.label).font(.headline)
                    HStack(spacing: 6) {
                        Text(context.attributes.startedAt, style: .timer)
                        Text("· \(context.state.conversationCount) conversations")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Button(intent: ToggleListeningIntent()) {
                    Text(context.state.phase.isPaused ? "Resume" : "Pause")
                        .font(.callout.bold())
                }
                .buttonStyle(.borderedProminent)
                .tint(context.state.phase.isPaused ? .green : .orange)
            }
            .padding()
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: context.state.phase.glyph)
                        .foregroundStyle(context.state.phase.tint)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.phase.label).font(.headline)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.attributes.startedAt, style: .timer)
                        .font(.headline)
                        .monospacedDigit()
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Button(intent: ToggleListeningIntent()) {
                        Text(context.state.phase.isPaused ? "Resume" : "Pause")
                    }
                    .buttonStyle(.borderedProminent)
                }
            } compactLeading: {
                Image(systemName: context.state.phase.compactGlyph)
                    .foregroundStyle(context.state.phase.tint)
            } compactTrailing: {
                EmptyView()
            } minimal: {
                Image(systemName: context.state.phase.compactGlyph)
                    .foregroundStyle(context.state.phase.tint)
            }
        }
    }
}
```

- [ ] **Step 8: Full test suite green, zero new warnings**

Run: `xcodebuild test -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone Air' 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 9: Commit**

```bash
git add Sotto/LiveActivity Sotto/Pipeline/ListeningPipeline.swift SottoWidgets/SottoWidgetsBundle.swift SottoTests
git commit -m "feat: phase-based Live Activity; VAD state on the Island, count off it"
```

---

### Task 2: SPEC amendments

**Files:**
- Modify: `docs/SPEC.md:123` (disk guard), `docs/SPEC.md:354` (Live Activity content spec)

**Interfaces:**
- Consumes: nothing from Task 1 (docs only).
- Produces: SPEC text matching shipped behavior; no code relies on it.

- [ ] **Step 1: Amend the disk-guard line (~123)**

Replace:
```
- _Disk guard_ — below 500 MB free: stop starting new segments, warn via notification + Live Activity.
```
with:
```
- _Disk guard_ — below 500 MB free: stop starting new segments, warn via notification.
```

- [ ] **Step 2: Amend the content spec (~354)**

Replace:
```
Content spec — lock screen & Dynamic Island (expanded): state label (Listening / Recording / Paused — call / Paused by you), elapsed listening time, today's conversation count, Pause/Resume button. Dynamic Island (compact): state glyph + count. Update on every state transition; no timers ticking faster than the system allows for Live Activity updates.
```
with:
```
Content spec — lock screen: state label (Listening / Recording / Paused — call / Paused by you), elapsed listening time, the session's conversation count (always labeled — never a bare number), Pause/Resume button. Dynamic Island (expanded): state glyph + label, elapsed time, Pause/Resume. Dynamic Island (compact/minimal): state glyph only, tinted by phase (green listening, red recording, orange paused) — no count. Update on every state transition; no timers ticking faster than the system allows for Live Activity updates.
```

- [ ] **Step 3: Commit**

```bash
git add docs/SPEC.md
git commit -m "docs: SPEC — Island shows VAD state without count; disk warning via notification only"
```

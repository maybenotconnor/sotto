# Home Header Refresh Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the home screen's "Sotto" large title + status row + banner strips with a single Porcelain glass status card (spec: `docs/superpowers/specs/2026-07-10-home-header-refresh-design.md`).

**Architecture:** A new `HeroCard.swift` owns the card view, a now-testable `HeaderState` enum (pure init instead of reading the pipeline inline), the footnote rows that replace the banner stack, and the `WaveMark` shape for the empty state. `ContentView.swift` shrinks: its header section becomes one `HeroCard`, and `statusCard`/`banners`/`NoticeBanner`/`PulsingDot`/`HeaderState` are deleted from it. Two adaptive colors (`Ink`, `Porcelain`) land in a new asset catalog. No model, pipeline, or settings changes.

**Tech Stack:** SwiftUI (iOS 26 Liquid Glass: `.glassEffect`, `.buttonStyle(.glassProminent)`), Swift Testing (`@Test`/`#expect`), XcodeGen.

## Global Constraints

- iOS deployment target 26.0; Swift 6; `SWIFT_DEFAULT_ACTOR_ISOLATION: nonisolated` (from `project.yml`).
- The project file is generated: after **adding or deleting files**, run `xcodegen generate` before building. Code-only edits inside existing files need no regen.
- Build: `xcodebuild build -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone Air' 2>&1 | tail -5` → `** BUILD SUCCEEDED **`
- Test: `xcodebuild test -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone Air' 2>&1 | tail -5` → `** TEST SUCCEEDED **`
- All user-facing copy is fixed by the spec — reuse the existing banner strings verbatim; new strings are exactly `"Ready to listen"` and `"On-device transcription model not downloaded."`.
- Commit messages: plain, imperative, no attribution trailers of any kind.
- Behavior is unchanged. This is a re-skin: same state machine, same banner trigger conditions, same actions.
- Base branch: written against `refactor/wearable-seam` at `c0e9d28` (post Omi-generalization). The wearable APIs are `model.pairedDeviceName`, `model.deviceConnectionState`, `model.pairedDeviceKind`, and `AppModel.bluetoothBannerReason(pairedDeviceName:connectionState:)`. If executing on a different base, re-verify these names first.

---

### Task 1: `Ink` and `Porcelain` adaptive colors

**Files:**
- Create: `Sotto/Assets.xcassets/Contents.json`
- Create: `Sotto/Assets.xcassets/Ink.colorset/Contents.json`
- Create: `Sotto/Assets.xcassets/Porcelain.colorset/Contents.json`

**Interfaces:**
- Consumes: nothing.
- Produces: `Color("Ink")` (light `#232752`, dark `#F2F2EF`) and `Color("Porcelain")` (light `#F2F2EF`, dark `#1A1D3C`), used by Tasks 3–5.

The `Sotto` target's source glob in `project.yml` covers `Sotto/` (excluding only `Resources/`), and XcodeGen treats `.xcassets` as resources automatically — no `project.yml` edit, just regeneration.

- [ ] **Step 1: Create the catalog root**

`Sotto/Assets.xcassets/Contents.json`:

```json
{
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
```

- [ ] **Step 2: Create the Ink colorset**

`Sotto/Assets.xcassets/Ink.colorset/Contents.json`:

```json
{
  "colors" : [
    {
      "color" : {
        "color-space" : "srgb",
        "components" : {
          "alpha" : "1.000",
          "blue" : "0x52",
          "green" : "0x27",
          "red" : "0x23"
        }
      },
      "idiom" : "universal"
    },
    {
      "appearances" : [
        {
          "appearance" : "luminosity",
          "value" : "dark"
        }
      ],
      "color" : {
        "color-space" : "srgb",
        "components" : {
          "alpha" : "1.000",
          "blue" : "0xEF",
          "green" : "0xF2",
          "red" : "0xF2"
        }
      },
      "idiom" : "universal"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
```

- [ ] **Step 3: Create the Porcelain colorset**

`Sotto/Assets.xcassets/Porcelain.colorset/Contents.json`:

```json
{
  "colors" : [
    {
      "color" : {
        "color-space" : "srgb",
        "components" : {
          "alpha" : "1.000",
          "blue" : "0xEF",
          "green" : "0xF2",
          "red" : "0xF2"
        }
      },
      "idiom" : "universal"
    },
    {
      "appearances" : [
        {
          "appearance" : "luminosity",
          "value" : "dark"
        }
      ],
      "color" : {
        "color-space" : "srgb",
        "components" : {
          "alpha" : "1.000",
          "blue" : "0x3C",
          "green" : "0x1D",
          "red" : "0x1A"
        }
      },
      "idiom" : "universal"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
```

- [ ] **Step 4: Regenerate and build**

Run: `xcodegen generate && xcodebuild build -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone Air' 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add Sotto/Assets.xcassets Sotto.xcodeproj
git commit -m "feat: add Ink and Porcelain adaptive colors"
```

---

### Task 2: Testable `HeaderState` in `HeroCard.swift`

**Files:**
- Create: `Sotto/App/HeroCard.swift` (the `HeaderState` enum only in this task)
- Test: `SottoTests/HeaderStateTests.swift`

**Interfaces:**
- Consumes: `ListeningPipeline.Status` (cases `idle, starting, listening, recording, silence, interrupted`), `ListeningPipeline.HaltReason` (cases `systemInterruption, userPause`) — both defined in `Sotto/Pipeline/ListeningPipeline.swift:13-28`.
- Produces: internal `HeaderState: Equatable` with `init(segmentStart: Date?, status: ListeningPipeline.Status, haltReason: ListeningPipeline.HaltReason?, sessionStart: Date?)` and members `label: String`, `dotColor: Color`, `timerStart: Date?`, `subtitle: String?`. Task 3 builds the view on it.

The enum currently lives as a `private` nested type inside `HomeScreen` (`ContentView.swift:393`), reading pipeline properties in a computed var. This task creates the internal, purely-derived twin; the old one is deleted in Task 3 (the two coexist without conflict meanwhile because the old one is `private` to `HomeScreen`).

- [ ] **Step 1: Write the failing tests**

`SottoTests/HeaderStateTests.swift`:

```swift
import Foundation
import Testing
@testable import Sotto

struct HeaderStateTests {
    @Test func openSegmentTakesPriorityOverStatus() {
        let segmentStart = Date(timeIntervalSince1970: 100)
        let state = HeaderState(
            segmentStart: segmentStart, status: .listening,
            haltReason: nil, sessionStart: Date(timeIntervalSince1970: 50))
        #expect(state == .segmentOpen(start: segmentStart))
        #expect(state.label == "Recording…")
        #expect(state.timerStart == segmentStart)
    }

    @Test func statusMapsToState() {
        #expect(HeaderState(segmentStart: nil, status: .idle, haltReason: nil, sessionStart: nil) == .idle)
        #expect(HeaderState(segmentStart: nil, status: .starting, haltReason: nil, sessionStart: nil) == .starting)
        #expect(HeaderState(segmentStart: nil, status: .interrupted, haltReason: .userPause, sessionStart: nil)
            == .interrupted(.userPause))
        let sessionStart = Date(timeIntervalSince1970: 5)
        for status in [ListeningPipeline.Status.listening, .recording, .silence] {
            #expect(HeaderState(segmentStart: nil, status: status, haltReason: nil, sessionStart: sessionStart)
                == .listening(sessionStart: sessionStart))
        }
    }

    @Test func pausedLabelsMatchHaltReason() {
        #expect(HeaderState.interrupted(.userPause).label == "Paused by you")
        #expect(HeaderState.interrupted(.systemInterruption).label == "Paused — call")
        #expect(HeaderState.interrupted(nil).label == "Paused — call")
    }

    @Test func oneTimerAtATime() {
        let sessionStart = Date(timeIntervalSince1970: 5)
        #expect(HeaderState.listening(sessionStart: sessionStart).timerStart == sessionStart)
        #expect(HeaderState.idle.timerStart == nil)
        #expect(HeaderState.starting.timerStart == nil)
        #expect(HeaderState.interrupted(nil).timerStart == nil)
    }

    @Test func subtitleOnlyWhenIdle() {
        #expect(HeaderState.idle.subtitle == "Ready to listen")
        #expect(HeaderState.starting.subtitle == nil)
        #expect(HeaderState.listening(sessionStart: nil).subtitle == nil)
        #expect(HeaderState.interrupted(.userPause).subtitle == nil)
        #expect(HeaderState.segmentOpen(start: Date(timeIntervalSince1970: 0)).subtitle == nil)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodegen generate && xcodebuild test -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone Air' -only-testing:SottoTests/HeaderStateTests 2>&1 | tail -5`
Expected: FAIL — compile error, `cannot find 'HeaderState' in scope` (the nested one in `ContentView.swift` is private).

- [ ] **Step 3: Write the implementation**

`Sotto/App/HeroCard.swift`:

```swift
import SwiftUI

/// The home header's state machine (moved from ContentView's HomeScreen, made internal
/// and purely derived so it is unit-testable). One segment-open case takes priority over
/// the raw pipeline status so the card morphs into "Recording…" instead of growing a
/// second header-like row (M9 decision, preserved by the 2026-07-10 header refresh).
enum HeaderState: Equatable {
    case idle
    case starting
    case interrupted(ListeningPipeline.HaltReason?)
    case listening(sessionStart: Date?)
    case segmentOpen(start: Date)

    init(
        segmentStart: Date?,
        status: ListeningPipeline.Status,
        haltReason: ListeningPipeline.HaltReason?,
        sessionStart: Date?
    ) {
        if let segmentStart {
            self = .segmentOpen(start: segmentStart)
        } else {
            switch status {
            case .idle: self = .idle
            case .starting: self = .starting
            case .interrupted: self = .interrupted(haltReason)
            case .listening, .recording, .silence:
                self = .listening(sessionStart: sessionStart)
            }
        }
    }

    var label: String {
        switch self {
        case .idle: "Idle"
        case .starting: "Starting…"
        case .interrupted(let reason): reason == .userPause ? "Paused by you" : "Paused — call"
        case .listening: "Listening"
        case .segmentOpen: "Recording…"
        }
    }

    var dotColor: Color {
        switch self {
        case .idle, .starting: .secondary
        case .interrupted: .orange
        case .listening: .green
        case .segmentOpen: .red
        }
    }

    /// One timer at a time: the segment timer while a segment is open, else the session
    /// timer while listening/silence, else none.
    var timerStart: Date? {
        switch self {
        case .segmentOpen(let start): start
        case .listening(let sessionStart): sessionStart
        case .idle, .starting, .interrupted: nil
        }
    }

    /// Static subtitle shown when no timer runs (spec: idle only).
    var subtitle: String? {
        if case .idle = self { return "Ready to listen" }
        return nil
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodegen generate && xcodebuild test -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone Air' -only-testing:SottoTests/HeaderStateTests 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add Sotto/App/HeroCard.swift SottoTests/HeaderStateTests.swift Sotto.xcodeproj
git commit -m "refactor: extract HeaderState into HeroCard.swift with pure derivation"
```

---

### Task 3: The card view; ContentView loses title and status row

**Files:**
- Modify: `Sotto/App/HeroCard.swift` (append view code)
- Modify: `Sotto/App/ContentView.swift`

**Interfaces:**
- Consumes: `HeaderState` (Task 2), `Color("Ink")`/`Color("Porcelain")` (Task 1), plus existing API already used by the old `statusCard`: `pipeline.start()`, `pipeline.resumeFromInterruption()`, `model.stopListening()`, `pipeline.activeSourceType?.displayName`, `model.pairedDeviceName`.
- Produces: `HeroCard(model:pipeline:micDenied:)` — `struct HeroCard: View { let model: AppModel; let pipeline: ListeningPipeline; let micDenied: Bool }`. Task 4 appends footnotes to it.

- [ ] **Step 1: Append the card view and PulsingDot to `HeroCard.swift`**

Add at the end of `Sotto/App/HeroCard.swift`:

```swift
/// The Porcelain hero: one glass surface carrying state dot + word, timer/subtitle, and a
/// compact action capsule (design: docs/superpowers/specs/2026-07-10-home-header-refresh-design.md).
/// Replaces HomeScreen's statusCard. Scrolls away with the list — the system mic indicator
/// and Live Activity carry the always-visible recording indication (pre-existing decision).
struct HeroCard: View {
    let model: AppModel
    let pipeline: ListeningPipeline
    let micDenied: Bool

    private var state: HeaderState {
        HeaderState(
            segmentStart: pipeline.currentSegmentStartDate,
            status: pipeline.status,
            haltReason: pipeline.haltReason,
            sessionStart: pipeline.sessionStartedAt)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 10) {
                if case .segmentOpen = state {
                    PulsingDot(color: .red)
                } else {
                    Circle().fill(state.dotColor).frame(width: 12, height: 12)
                }
                stateWord
                    .font(.title2.bold())
                    .foregroundStyle(Color("Ink"))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 8)
                actionButton
            }
            subtitleLine
        }
        .padding(16)
        .glassEffect(.regular, in: .rect(cornerRadius: 26))
        .background(Color("Porcelain").opacity(0.55), in: .rect(cornerRadius: 26))
    }

    /// M12: source suffix only when a wearable is paired — phone-mic-only users see the
    /// exact same label as before (SPEC "UI & surfacing"; carried over from statusCard).
    private var stateWord: Text {
        if let source = pipeline.activeSourceType, model.pairedDeviceName != nil {
            return Text("\(state.label) · \(source.displayName)")
        }
        return Text(state.label)
    }

    @ViewBuilder private var subtitleLine: some View {
        if let timerStart = state.timerStart {
            Text(timerStart, style: .timer)
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.leading, 22)
        } else if let subtitle = state.subtitle {
            Text(subtitle)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.leading, 22)
        }
    }

    private var actionButton: some View {
        Button(buttonLabel) {
            Task {
                switch pipeline.status {
                case .idle: await pipeline.start()
                case .interrupted: await pipeline.resumeFromInterruption()
                // Routed through AppModel (not a direct pipeline.stop()) so a pair/forget
                // that happened mid-session gets its deferred rebuild the moment this
                // session actually ends (M12 final review Important #2).
                default: await model.stopListening()
                }
            }
        }
        .buttonStyle(.glassProminent)
        .tint(Color("Ink"))
        .disabled(micDenied && (pipeline.status == .idle || pipeline.status == .interrupted))
    }

    private var buttonLabel: String {
        switch pipeline.status {
        case .idle: "Start Listening"
        case .interrupted: "Resume"
        default: "Stop"
        }
    }
}

/// Pulsing dot for the card's segment-open state (moved verbatim from ContentView.swift).
struct PulsingDot: View {
    let color: Color
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 12, height: 12)
            .opacity(pulsing ? 0.35 : 1.0)
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulsing)
            .onAppear { pulsing = true }
    }
}
```

Note the single button style everywhere: Ink capsule (its dark variant makes the paper button at night). No red button, no `.accentColor` — the action word carries the meaning (spec "Decisions").

- [ ] **Step 2: Swap it into `ContentView.swift`**

Three edits:

1. In `ContentView.body`, delete the line `.navigationTitle("Sotto")` (line 38). No replacement — the screen has no title; the toolbar items remain.

2. In `HomeScreen.body`, replace the header section's `statusCard` with the card (the `banners` line stays until Task 4):

```swift
Section {
    HeroCard(model: model, pipeline: pipeline, micDenied: micDenied)
        .selectionDisabled(true)
    banners
        .selectionDisabled(true)
}
.listRowSeparator(.hidden)
```

3. Delete from `HomeScreen` / file scope, now dead: the `statusCard` computed property, the `buttonLabel` computed property, the `private enum HeaderState` and the `headerState` computed property, and the file-private `PulsingDot` struct. Also update `HomeScreen`'s doc comment (lines 67–72) to:

```swift
/// M9 unified home, reskinned 2026-07-10 (home-header-refresh spec): a single Porcelain
/// HeroCard carries state + timer + action (and, after the banner fold-in, all notices),
/// then infinite-scroll history with sticky day headers, newest first. The card scrolls
/// away with the list — the system orange mic dot and the Live Activity carry the
/// always-visible recording indication.
```

- [ ] **Step 3: Build and run the full test suite**

Run: `xcodebuild test -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone Air' 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **` (no files added — no regen needed)

- [ ] **Step 4: Commit**

```bash
git add Sotto/App/HeroCard.swift Sotto/App/ContentView.swift
git commit -m "feat: replace Sotto title and status row with porcelain hero card"
```

---

### Task 4: Banners become footnotes inside the card

**Files:**
- Modify: `Sotto/App/HeroCard.swift`
- Modify: `Sotto/App/ContentView.swift`

**Interfaces:**
- Consumes: existing notice API already used by the old `banners` view: `model.recoveryNotice`, `model.dismissRecoveryNotice()`, `model.assetState` (cases `.downloading(fraction)`, `.notInstalled`, `.failed`, `.unsupported`), `model.downloadSpeechModel()`, `model.settings.transcriptionEngine`, `TranscriptionBackend`, `AppModel.bluetoothBannerReason(pairedDeviceName:connectionState:)` (returns `.poweredOff` or other), `model.pairedDeviceKind?.displayName`, `pipeline.diskGuardActive`, `UIApplication.openSettingsURLString`.
- Produces: nothing new outside `HeroCard` — the card is now self-contained.

Banner copy is reused **verbatim** from `ContentView.swift:310-378`. Trigger conditions are identical; only presentation changes (footnote rows under a divider instead of full-weight list rows).

- [ ] **Step 1: Add footnotes to `HeroCard.swift`**

Add `import UIKit` under `import SwiftUI` at the top of the file. Inside `HeroCard`, add the `@AppStorage` mirror (moved from `HomeScreen`, same rationale comment) after the stored properties:

```swift
    /// `model.settings` is UserDefaults-backed, not @Observable — @AppStorage observes the
    /// same defaults key so the unsupported-engine footnote updates when Settings changes
    /// the engine; nil (pre-M10 installs) falls back to the store's migrating getter.
    /// (Moved from HomeScreen with the banner fold-in.)
    @AppStorage("transcriptionEngine") private var engineRaw: String?
    private var onDeviceEngineSelected: Bool {
        let engine = engineRaw.flatMap(TranscriptionBackend.init(rawValue:))
            ?? model.settings.transcriptionEngine
        return engine == .speechAnalyzer
    }
```

In `body`, add `footnotes` after `subtitleLine`:

```swift
            subtitleLine
            footnotes
```

Then add to `HeroCard`:

```swift
    /// The former full-weight banner stack, folded into the card as footnote rows —
    /// same copy, same actions, same trigger conditions (spec "Banners → footnotes").
    @ViewBuilder private var footnotes: some View {
        if hasFootnotes {
            Divider()
                .padding(.top, 12)
            VStack(alignment: .leading, spacing: 8) {
                if let notice = model.recoveryNotice {
                    FootnoteRow(
                        symbol: "exclamationmark.triangle", isWarning: true, text: notice,
                        actionLabel: "Dismiss") { model.dismissRecoveryNotice() }
                }
                if case .downloading(let fraction) = model.assetState {
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: fraction)
                        Text("Preparing on-device transcription — recordings are saved and will be transcribed when it's ready.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else if case .notInstalled = model.assetState {
                    FootnoteRow(
                        symbol: "arrow.down.circle",
                        text: "On-device transcription model not downloaded.",
                        actionLabel: "Download") { Task { await model.downloadSpeechModel() } }
                } else if case .failed = model.assetState {
                    FootnoteRow(
                        symbol: "arrow.down.circle", isWarning: true,
                        text: "Model download failed — check your connection.",
                        actionLabel: "Try again") { Task { await model.downloadSpeechModel() } }
                } else if case .unsupported = model.assetState, onDeviceEngineSelected {
                    FootnoteRow(
                        symbol: "exclamationmark.triangle",
                        text: "This device doesn't support on-device transcription. Select another transcription engine in Settings.")
                }
                if micDenied {
                    FootnoteRow(
                        symbol: "mic.slash", isWarning: true,
                        text: "Microphone access is off. Sotto can't listen without it.",
                        actionLabel: "Open Settings", action: openSettings)
                }
                if let reason = AppModel.bluetoothBannerReason(
                    pairedDeviceName: model.pairedDeviceName, connectionState: model.deviceConnectionState) {
                    // pairedDeviceKind is non-nil whenever the banner shows (name/kind are set
                    // together); the fallback is compiler-required. (Same pattern as the old banner.)
                    let deviceName = model.pairedDeviceKind?.displayName ?? "device"
                    FootnoteRow(
                        symbol: "antenna.radiowaves.left.and.right.slash", isWarning: true,
                        text: reason == .poweredOff
                            ? "Bluetooth is off — your \(deviceName) can't connect. Recording uses the iPhone mic."
                            : "Sotto needs Bluetooth permission to use your \(deviceName). Recording uses the iPhone mic.",
                        actionLabel: "Open Settings", action: openSettings)
                }
                if pipeline.diskGuardActive {
                    FootnoteRow(
                        symbol: "externaldrive.badge.exclamationmark", isWarning: true,
                        text: "Low disk space — new recordings are paused.")
                }
            }
            .padding(.top, 10)
        }
    }

    /// Mirrors every footnote condition above — gates the Divider so an all-clear card
    /// has no trailing hairline.
    private var hasFootnotes: Bool {
        if model.recoveryNotice != nil { return true }
        switch model.assetState {
        case .downloading, .notInstalled, .failed: return true
        case .unsupported: if onDeviceEngineSelected { return true }
        default: break
        }
        if micDenied { return true }
        if AppModel.bluetoothBannerReason(
            pairedDeviceName: model.pairedDeviceName, connectionState: model.deviceConnectionState) != nil {
            return true
        }
        return pipeline.diskGuardActive
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
```

And at file scope (below `PulsingDot`):

```swift
/// One notice line inside the card: leading symbol, footnote text, optional trailing bold
/// action. Warning rows tint the symbol red, not the body text (spec). Explicit button
/// style is required — the row lives inside a List row that already contains other buttons.
private struct FootnoteRow: View {
    let symbol: String
    var isWarning = false
    let text: String
    var actionLabel: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .font(.footnote)
                .foregroundStyle(isWarning ? Color.red : Color.secondary)
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let actionLabel, let action {
                Button(actionLabel, action: action)
                    .font(.footnote.bold())
                    .buttonStyle(.plain)
                    .foregroundStyle(Color("Ink"))
            }
        }
    }
}
```

- [ ] **Step 2: Delete the old banner machinery from `ContentView.swift`**

1. Header section shrinks to the card alone:

```swift
Section {
    HeroCard(model: model, pipeline: pipeline, micDenied: micDenied)
        .selectionDisabled(true)
}
.listRowSeparator(.hidden)
```

2. Delete from `HomeScreen`: the `@AppStorage("transcriptionEngine")` property, `onDeviceEngineSelected`, and the whole `banners` `@ViewBuilder` (lines 114–122 and 309–379 in the pre-refresh file).
3. Delete the file-private `NoticeBanner` struct.
4. If `import UIKit` in `ContentView.swift` is now unused (its only uses were `UIApplication` calls in `banners`), remove it — verify with `grep -n "UI" Sotto/App/ContentView.swift` first (`UIApplication`, `UIKit` should be gone; `EditMode`/SwiftUI types don't need it).

- [ ] **Step 3: Build and run the full test suite**

Run: `xcodebuild test -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone Air' 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add Sotto/App/HeroCard.swift Sotto/App/ContentView.swift
git commit -m "feat: fold notice banners into hero card footnotes"
```

---

### Task 5: Wave mark in the empty state

**Files:**
- Modify: `Sotto/App/HeroCard.swift` (append `WaveMark`)
- Modify: `Sotto/App/ContentView.swift` (empty-state section)

**Interfaces:**
- Consumes: `Color("Ink")` (Task 1); the wave centerline geometry from `docs/superpowers/specs/2026-07-10-app-icon-design.md` ("Geometry" table).
- Produces: `struct WaveMark: Shape` (internal, in `HeroCard.swift`).

The icon spec's filled-outline constraint was Icon-Composer-specific; SwiftUI strokes the centerline directly with round caps.

- [ ] **Step 1: Append `WaveMark` to `HeroCard.swift`**

```swift
/// The app icon's speech-line — a decaying waveform settling into a ruled line — as a
/// SwiftUI Shape. Centerline geometry is copied from the icon spec's 160-unit space
/// (docs/superpowers/specs/2026-07-10-app-icon-design.md) and fit-scaled into rect.
struct WaveMark: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 26, y: 52))
        path.addCurve(
            to: CGPoint(x: 36, y: 42),
            control1: CGPoint(x: 28.5, y: 47.5), control2: CGPoint(x: 32, y: 42))
        path.addCurve(
            to: CGPoint(x: 54, y: 60),
            control1: CGPoint(x: 44, y: 42), control2: CGPoint(x: 46, y: 60))
        path.addCurve(
            to: CGPoint(x: 68, y: 47),
            control1: CGPoint(x: 61, y: 60), control2: CGPoint(x: 61, y: 47))
        path.addCurve(
            to: CGPoint(x: 78, y: 52),
            control1: CGPoint(x: 72, y: 47), control2: CGPoint(x: 74, y: 52))
        path.addLine(to: CGPoint(x: 134, y: 52))

        let bounds = CGRect(x: 26, y: 42, width: 108, height: 18)
        let scale = min(rect.width / bounds.width, rect.height / bounds.height)
        let transform = CGAffineTransform.identity
            .translatedBy(x: rect.midX, y: rect.midY)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -bounds.midX, y: -bounds.midY)
        return path.applying(transform)
    }
}
```

- [ ] **Step 2: Add the wave to the empty state in `ContentView.swift`**

Replace the empty-state section body (the `Text(emptyStateText)` section, pre-refresh lines 155–163):

```swift
} else if model.historySections.isEmpty && model.hasLoadedHistoryOnce {
    Section {
        VStack(spacing: 14) {
            WaveMark()
                .stroke(
                    Color("Ink").opacity(0.55),
                    style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .frame(width: 150, height: 30)
            Text(emptyStateText)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 24)
        .selectionDisabled(true)
    }
    .listRowSeparator(.hidden)
}
```

(`emptyStateText` and its three copy variants are unchanged.)

- [ ] **Step 3: Build and run the full test suite**

Run: `xcodebuild test -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone Air' 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add Sotto/App/HeroCard.swift Sotto/App/ContentView.swift
git commit -m "feat: wave mark greets the empty state"
```

---

### Task 6: Verification pass (spec checklist)

**Files:** none created — this task drives the app in the simulator against the spec's "Verification" section. Fix-forward anything that fails, amending the relevant task's code, and commit fixes as `fix:` commits.

- [ ] **Step 1: Install a fresh copy on the simulator**

```bash
xcrun simctl boot "iPhone Air" 2>/dev/null || true
xcodebuild build -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone Air' 2>&1 | tail -2
APP=$(find ~/Library/Developer/Xcode/DerivedData -path "*Build/Products/Debug-iphonesimulator/Sotto.app" -newer project.yml | head -1)
xcrun simctl uninstall booted com.decanlys.Sotto 2>/dev/null || true
xcrun simctl install booted "$APP"
xcrun simctl launch booted com.decanlys.Sotto
```

Expected: app launches to the title-less home screen — glass card reading "Idle · Ready to listen · Start Listening", wave mark + empty-state text below (spec check 5: fresh install shows the wave).

- [ ] **Step 2: Drive the states (spec check 1)**

In the simulator: complete onboarding if shown, grant mic permission, tap **Start Listening** → card shows green dot "Listening" + counting timer + **Stop**. Speak (or play audio) → card morphs to pulsing red dot "Recording…" + segment timer. Tap **Stop** → back to "Idle". Confirm the wave mark disappears from the empty state once the first conversation appears in history.

- [ ] **Step 3: Mic-denied footnote (spec check 2)**

```bash
xcrun simctl privacy booted revoke microphone com.decanlys.Sotto
xcrun simctl launch booted com.decanlys.Sotto
```

Expected: card gains hairline + `mic.slash` footnote "Microphone access is off. Sotto can't listen without it." with a working **Open Settings** action; **Start Listening** is disabled. Restore afterwards: `xcrun simctl privacy booted grant microphone com.decanlys.Sotto`.

- [ ] **Step 4: Dark mode (spec check 4)**

```bash
xcrun simctl ui booted appearance dark
```

Expected: card inverts to an ink surface, state word and wave go porcelain, the action button becomes a paper capsule with ink label. Then `xcrun simctl ui booted appearance light` to restore.

- [ ] **Step 5: Dynamic Type and edit mode (spec checks 6–7)**

Simulator → Settings → Accessibility → Display & Text Size → Larger Text → maximum. Expected: state word scales (min-scale keeps it on one line or wraps gracefully), button stays tappable. Back in Sotto with ≥2 same-day conversations: tap **Select** → card stays inert (no selection circle), merge bar appears at the bottom unchanged.

- [ ] **Step 6: Unsupported-engine footnote (spec check 3)**

On the simulator (SpeechAnalyzer assets typically unavailable): with the on-device engine selected in Settings, confirm the `exclamationmark.triangle` footnote shows the unchanged copy "This device doesn't support on-device transcription. Select another transcription engine in Settings." If the simulator reports the engine as supported instead, verify by temporarily setting `assetState = .unsupported` is NOT needed — skip with a note; the copy and trigger condition are covered by code inspection (they are verbatim from the old banner).

- [ ] **Step 7: Final commit if fixes were needed**

```bash
git status --short   # expect clean; commit any fix-forward changes made above
```

---

## Self-Review (completed)

- **Spec coverage:** structure/no-title (Task 3), card anatomy + button (Task 3), states (Tasks 2–3), banners→footnotes incl. symbol list (Task 4), empty-state wave (Task 5), colors (Task 1), verification list (Task 6). No gaps.
- **Placeholders:** none — every code step carries complete code, every banner string verbatim.
- **Type consistency:** `HeaderState` init signature identical in Tasks 2 (definition/tests) and 3 (call site); `HeroCard(model:pipeline:micDenied:)` identical in Tasks 3–5; `FootnoteRow(symbol:isWarning:text:actionLabel:action:)` used only within Task 4.

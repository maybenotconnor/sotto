# Ink Prominent Button Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extract the hero button's glass + Ink + Porcelain treatment into a reusable `.inkProminent()` helper and adopt it on all 7 prominent action buttons, including the Live Activity (spec: `docs/superpowers/specs/2026-07-10-ink-prominent-button-design.md`).

**Architecture:** One `View` extension in a new `Sotto/App/InkProminent.swift`, compiled into both the app and widget targets. Call sites swap their style modifiers for `.inkProminent()`; the widget target additionally gains the shared asset catalog so `Color("Ink")`/`Color("Porcelain")` resolve in the extension bundle. Pure re-skin — no action, layout, or copy changes.

**Tech Stack:** SwiftUI (iOS 26 `.glassProminent`), XcodeGen, ActivityKit (existing Live Activity).

## Global Constraints

- iOS deployment target 26.0; Swift 6; `SWIFT_DEFAULT_ACTOR_ISOLATION: nonisolated` (from `project.yml`).
- The project file is generated: after **adding or deleting files, or editing `project.yml`**, run `xcodegen generate` before building. Code-only edits inside existing files need no regen. `Sotto.xcodeproj` is gitignored — never `git add` it.
- Build: `xcodebuild build -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone Air' 2>&1 | tail -5` → `** BUILD SUCCEEDED **` (the Sotto target embeds SottoWidgets, so widget compile errors surface here too).
- Test: `xcodebuild test -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone Air' 2>&1 | tail -5` → `** TEST SUCCEEDED **`
- Commit messages: plain, imperative, no attribution trailers of any kind.
- Behavior is unchanged everywhere: same actions, same disabled conditions, same copy. Only button styling changes.
- No new unit tests: the change is pure view styling and the repo has no snapshot-test infrastructure (adding one is out of scope). Verification is the full existing suite plus the simulator pass in Task 4.
- Base branch: written against `feature/ink-prominent-button` at `f46b260` (stacked on the home-header-refresh branch — requires `HeroCard.swift` and the `Ink`/`Porcelain` colorsets from that work).

---

### Task 1: `InkProminent.swift` + hero card adoption

**Files:**
- Create: `Sotto/App/InkProminent.swift`
- Modify: `Sotto/App/HeroCard.swift` (the `actionButton` modifiers)

**Interfaces:**
- Consumes: `Color("Ink")` / `Color("Porcelain")` (asset catalog, from the header-refresh work), `.glassProminent` (SwiftUI built-in).
- Produces: `extension View { func inkProminent() -> some View }` — internal, used by Tasks 2–3.

- [ ] **Step 1: Create the shared extension**

`Sotto/App/InkProminent.swift`:

```swift
import SwiftUI

extension View {
    /// Sotto's prominent action treatment: a Liquid Glass capsule tinted Ink whose label
    /// is explicitly Porcelain, so both layers invert together — ink capsule with paper
    /// label by day, paper capsule with ink label at night (the header spec's "ink by
    /// day, paper by night", extended app-wide by the 2026-07-10 ink-prominent spec).
    /// The explicit label color is load-bearing: .glassProminent keeps a light label on
    /// the tint in BOTH modes, which turns white-on-porcelain (unreadable) in dark mode.
    /// Compiled into the app and widget targets; both bundles carry the colorsets.
    func inkProminent() -> some View {
        buttonStyle(.glassProminent)
            .tint(Color("Ink"))
            .foregroundStyle(Color("Porcelain"))
    }
}
```

- [ ] **Step 2: Swap the hero button's inline modifiers**

In `Sotto/App/HeroCard.swift`, `actionButton` currently ends with:

```swift
        .buttonStyle(.glassProminent)
        .tint(Color("Ink"))
        // .glassProminent keeps a light label on the tint in both modes, which turns
        // white-on-porcelain (unreadable) at night — the label must invert WITH the
        // capsule, so it uses the opposing asset color explicitly ("ink by day, paper
        // by night" from the spec, applied to both layers of the button).
        .foregroundStyle(Color("Porcelain"))
        .disabled(micDenied && (pipeline.status == .idle || pipeline.status == .interrupted))
```

Replace those lines with (the comment's content now lives on the extension):

```swift
        .inkProminent()
        .disabled(micDenied && (pipeline.status == .idle || pipeline.status == .interrupted))
```

- [ ] **Step 3: Regenerate (new file), build, run the full suite**

Run: `xcodegen generate && xcodebuild test -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone Air' 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add Sotto/App/InkProminent.swift Sotto/App/HeroCard.swift
git commit -m "refactor: extract ink prominent button treatment into shared helper"
```

---

### Task 2: Onboarding and merge bar adopt `.inkProminent()`

**Files:**
- Modify: `Sotto/App/OnboardingView.swift` (4 buttons)
- Modify: `Sotto/App/ContentView.swift` (merge bar button)

**Interfaces:**
- Consumes: `.inkProminent()` (Task 1).
- Produces: nothing new.

- [ ] **Step 1: Restyle the four onboarding buttons**

In `Sotto/App/OnboardingView.swift`, replace each `.buttonStyle(.borderedProminent)` with `.inkProminent()` at exactly these four sites (leave the plain-text "Skip for now — recordings still save" button untouched):

```swift
                Button("Start using Sotto") { completeIfConsented() }.inkProminent()
```

```swift
                Button("Continue") { completeIfConsented() }
                    .inkProminent()
```

```swift
                Button("Download model") { Task { await model.downloadSpeechModel() } }
                    .inkProminent()
```

```swift
            Button(button, action: action).inkProminent()
```

- [ ] **Step 2: Restyle the merge bar button**

In `Sotto/App/ContentView.swift`, the merge bar inside `.safeAreaInset(edge: .bottom)` currently reads:

```swift
                    Button {
                        confirmingMerge = true
                    } label: {
                        if merging {
                            ProgressView()
                        } else {
                            Text("Merge \(mergeCount) conversations")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(merging || { if case .eligible = eligibility { false } else { true } }())
```

Replace with (the spinner needs an explicit Porcelain tint — `.inkProminent()` sets the
button's tint to Ink, which the spinner would inherit and vanish into the capsule):

```swift
                    Button {
                        confirmingMerge = true
                    } label: {
                        if merging {
                            ProgressView()
                                .tint(Color("Porcelain"))
                        } else {
                            Text("Merge \(mergeCount) conversations")
                        }
                    }
                    .inkProminent()
                    .disabled(merging || { if case .eligible = eligibility { false } else { true } }())
```

- [ ] **Step 3: Build and run the full suite** (code-only edits — no regen)

Run: `xcodebuild test -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone Air' 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add Sotto/App/OnboardingView.swift Sotto/App/ContentView.swift
git commit -m "feat: onboarding and merge bar adopt the ink prominent button"
```

---

### Task 3: Live Activity buttons + widget target plumbing

**Files:**
- Modify: `project.yml` (SottoWidgets sources)
- Modify: `SottoWidgets/SottoWidgetsBundle.swift` (2 buttons)

**Interfaces:**
- Consumes: `.inkProminent()` (Task 1); `Sotto/Assets.xcassets` colorsets.
- Produces: nothing new.

- [ ] **Step 1: Share the helper and the colors with the widget target**

In `project.yml`, the `SottoWidgets` target's sources currently read:

```yaml
    sources:
      - path: SottoWidgets
      - path: Sotto/LiveActivity/SottoActivityAttributes.swift
      - path: Sotto/LiveActivity/ToggleListeningIntent.swift
```

Add two entries (XcodeGen puts `.xcassets` in the resources build phase automatically):

```yaml
    sources:
      - path: SottoWidgets
      - path: Sotto/LiveActivity/SottoActivityAttributes.swift
      - path: Sotto/LiveActivity/ToggleListeningIntent.swift
      - path: Sotto/App/InkProminent.swift
      - path: Sotto/Assets.xcassets
```

- [ ] **Step 2: Restyle the two Pause/Resume buttons**

In `SottoWidgets/SottoWidgetsBundle.swift`, the lock-screen button currently reads:

```swift
                Button(intent: ToggleListeningIntent()) {
                    Text(context.state.phase.isPaused ? "Resume" : "Pause")
                        .font(.callout.bold())
                }
                .buttonStyle(.borderedProminent)
                .tint(context.state.phase.isPaused ? .green : .orange)
```

Replace with (the state-color signal moves entirely to the glyph — deliberate spec
decision extending "the action word carries the meaning" to the lock screen):

```swift
                Button(intent: ToggleListeningIntent()) {
                    Text(context.state.phase.isPaused ? "Resume" : "Pause")
                        .font(.callout.bold())
                }
                .inkProminent()
```

And the Dynamic Island expanded button:

```swift
                    Button(intent: ToggleListeningIntent()) {
                        Text(context.state.phase.isPaused ? "Resume" : "Pause")
                    }
                    .buttonStyle(.borderedProminent)
```

becomes:

```swift
                    Button(intent: ToggleListeningIntent()) {
                        Text(context.state.phase.isPaused ? "Resume" : "Pause")
                    }
                    .inkProminent()
```

Do NOT touch `phase.tint` or its glyph usages — the glyphs keep their state colors.

- [ ] **Step 3: Regenerate (project.yml changed), build, run the full suite**

Run: `xcodegen generate && xcodebuild test -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone Air' 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add project.yml SottoWidgets/SottoWidgetsBundle.swift
git commit -m "feat: live activity buttons adopt the ink prominent treatment"
```

---

### Task 4: Verification pass (spec checklist)

**Files:** none — simulator verification against the spec's "Verification" section. Fix-forward failures as `fix:` commits.

- [ ] **Step 1: Fresh install, onboarding in light and dark (spec check 2)**

```bash
xcrun simctl boot "iPhone Air" 2>/dev/null || true
xcodebuild build -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone Air' 2>&1 | tail -2
APP=$(find ~/Library/Developer/Xcode/DerivedData -path "*Build/Products/Debug-iphonesimulator/Sotto.app" | head -1)
xcrun simctl uninstall booted com.decanlys.Sotto 2>/dev/null || true
xcrun simctl install booted "$APP"
xcrun simctl ui booted appearance light
xcrun simctl launch booted com.decanlys.Sotto
```

Screenshot the first onboarding card, then `xcrun simctl ui booted appearance dark` and screenshot again. Expected: the card's button is an ink capsule with porcelain label in light, a paper capsule with ink label in dark.

- [ ] **Step 2: Hero card regression (spec check 2)**

Skip onboarding (`xcrun simctl spawn booted defaults write com.decanlys.Sotto hasCompletedOnboarding -bool true`, grant mic, relaunch); screenshot home in both appearances. Expected: identical to the header-refresh result — the extraction changed nothing visually.

- [ ] **Step 3: Merge bar and Live Activity (spec checks 3–4) — best effort**

Both need app states this environment can't reliably produce (merge bar needs ≥2 same-day finalized conversations; the Live Activity button is only visible on the lock screen or long-pressed Dynamic Island, and the simulator can't be locked without assistive access). Verify what's reachable; where the simulator can't produce the state, note it in the final report for an on-device check — the styling mechanism is identical to the sites verified in Steps 1–2, and the spec's escape hatch (fall back to `.borderedProminent` + same colors in the widget file) stays available if Connor sees glass misrender on device.

- [ ] **Step 4: Clean status**

```bash
git status --short   # expect clean; commit any fix-forward changes made above
```

---

## Self-Review (completed)

- **Spec coverage:** mechanism/extension (Task 1), hero swap (Task 1), onboarding ×4 + merge bar with spinner tint (Task 2), Live Activity ×2 + plumbing + escape hatch (Task 3), verification incl. best-effort boundaries (Task 4). No gaps.
- **Placeholders:** none — every code step shows the exact before/after code.
- **Type consistency:** `inkProminent()` signature identical across Tasks 1–3; asset color names match the committed colorsets (`Ink`, `Porcelain`).

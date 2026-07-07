# M10 — Transcription Engine Picker Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the "Use Deepgram (cloud)" toggle with an explicit engine Picker (On-device / Deepgram), backed by an enum setting that migrates from the legacy `deepgramEnabled` bool, plus launch diagnostics for the observed toggle-reset mystery.

**Architecture:** `SettingsStore` gains `transcriptionEngine: TranscriptionBackend` stored under a new `"transcriptionEngine"` defaults key; the getter falls back to the legacy `"deepgramEnabled"` bool so existing installs keep their choice. The existing `TranscriptionBackend` enum (`speechAnalyzer`/`deepgram`, `Sotto/Transcription/TranscriptionService.swift:5`) is reused as the setting's type — no parallel enum. The two AppModel gates (per-job backend provider + launch-drain gate) switch from the bool to the enum. SettingsView's toggle becomes a Picker; the Deepgram sub-fields (key, test, Wi-Fi-only) show only when Deepgram is selected, with an inline warning when no key exists (the runtime silently falls back to on-device — the UI must say so). A one-line os.Logger launch log records the raw stored engine value + keychain presence so the next "toggle reset itself" occurrence is diagnosable from Console.app.

**Tech Stack:** SwiftUI Form/Picker, UserDefaults-backed `SettingsStore`, Swift Testing.

**Diagnostics context (user-reported, 2026-07-05):** Deepgram toggle observed off after some simulator relaunches while the keychain key survived, and onboarding did NOT reappear (so the defaults plist wasn't wiped). No code path writes `false` except the Settings toggle itself. The launch log in Task 2 exists to catch the next occurrence with evidence instead of guesses. The migration in Task 1 also means an unset new key falls back to the legacy key, adding one more layer of persistence robustness.

## Global Constraints

- Test command: `xcodebuild test -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone Air' 2>&1 | tail -5` → `** TEST SUCCEEDED **`. New files → `xcodegen generate` (this plan creates no new files). Zero Swift warnings (appintents exempt). Swift 6, `SWIFT_DEFAULT_ACTOR_ISOLATION: nonisolated`.
- Behavior that must NOT change: backend selection semantics (Deepgram only when chosen AND a keychain key exists, resolved fresh per job; silent fallback to on-device otherwise); Wi-Fi-only gating; key storage stays in the Keychain, never UserDefaults.
- The legacy `"deepgramEnabled"` defaults key is READ for migration but never written again; do not delete it from existing installs.
- Commits end with:

  Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>

## File Structure

```
Sotto/Files/RetentionPolicy.swift      ← replace deepgramEnabled property with transcriptionEngine (modify)
Sotto/App/AppModel.swift               ← two gate call sites + launch diagnostics log (modify)
Sotto/App/SettingsView.swift           ← Picker UI replacing the toggle (modify)
SottoTests/RetentionTests.swift        ← settings tests: default, migration, precedence (modify)
```

---

### Task 1: `SettingsStore.transcriptionEngine` with legacy migration (+ call sites)

**Files:**
- Modify: `Sotto/Files/RetentionPolicy.swift` (the `deepgramEnabled` property, lines 87–95)
- Modify: `Sotto/App/AppModel.swift` (the two `settings.deepgramEnabled` reads: the per-job provider gate ~line 440 and the launch-drain gate ~line 566 — deleting the old property breaks them, so they change in the same task to keep every commit building)
- Test: `SottoTests/RetentionTests.swift`

**Interfaces:**
- Consumes: existing `TranscriptionBackend` enum (`Sotto/Transcription/TranscriptionService.swift:5`): `enum TranscriptionBackend: String, Codable, Sendable { case speechAnalyzer, deepgram }`.
- Produces: `SettingsStore.transcriptionEngine: TranscriptionBackend { get nonmutating set }` — Tasks 2 and 3 call exactly this. The old `SettingsStore.deepgramEnabled` property is DELETED in this task.

- [ ] **Step 1: Write the failing tests**

In `SottoTests/RetentionTests.swift`, replace line 29 (`#expect(settings.deepgramEnabled == false)`) with:

```swift
        #expect(settings.transcriptionEngine == .speechAnalyzer)
```

and add this test to the `RetentionTests` struct:

```swift
    @Test func transcriptionEngineMigratesFromLegacyToggle() {
        let suite = UserDefaults(suiteName: "engine-migration-\(UUID().uuidString)")!
        let settings = SettingsStore(defaults: suite)
        #expect(settings.transcriptionEngine == .speechAnalyzer)   // fresh install default

        suite.set(true, forKey: "deepgramEnabled")                 // legacy M6b install
        #expect(settings.transcriptionEngine == .deepgram)         // migrated read

        settings.transcriptionEngine = .speechAnalyzer             // explicit choice wins over legacy
        #expect(settings.transcriptionEngine == .speechAnalyzer)
        #expect(suite.string(forKey: "transcriptionEngine") == "speechAnalyzer")
        #expect(suite.bool(forKey: "deepgramEnabled") == true)     // legacy key untouched

        suite.set("garbage", forKey: "transcriptionEngine")        // corrupted new key falls back
        #expect(settings.transcriptionEngine == .deepgram)         // to the legacy bool (still true here)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone Air' -only-testing:SottoTests/RetentionTests 2>&1 | tail -10`
Expected: BUILD FAILURE — `value of type 'SettingsStore' has no member 'transcriptionEngine'` (compile-time failure counts as the failing state here).

- [ ] **Step 3: Implement the setting**

In `Sotto/Files/RetentionPolicy.swift`, replace the whole `deepgramEnabled` property (lines 87–95):

```swift
    /// M6b's "Use Deepgram" toggle; Task 1's provider closure already requires a Keychain key before
    /// picking Deepgram — this adds the explicit user-facing opt-in on top of that.
    var deepgramEnabled: Bool {
        get {
            defaults.object(forKey: "deepgramEnabled") == nil
                ? false : defaults.bool(forKey: "deepgramEnabled")
        }
        nonmutating set { defaults.set(newValue, forKey: "deepgramEnabled") }
    }
```

with:

```swift
    /// M10 engine picker (supersedes M6b's "Use Deepgram" bool). Reads the legacy
    /// `deepgramEnabled` key as a migration fallback so pre-M10 installs keep their choice;
    /// writes only the new key. AppModel's provider closure still requires a Keychain key
    /// before actually picking Deepgram — this is the user's *preference*, not a guarantee.
    var transcriptionEngine: TranscriptionBackend {
        get {
            if let raw = defaults.string(forKey: "transcriptionEngine"),
               let engine = TranscriptionBackend(rawValue: raw) {
                return engine
            }
            return defaults.bool(forKey: "deepgramEnabled") ? .deepgram : .speechAnalyzer
        }
        nonmutating set { defaults.set(newValue.rawValue, forKey: "transcriptionEngine") }
    }
```

- [ ] **Step 4: Update the two AppModel gates that used the deleted property**

In `Sotto/App/AppModel.swift`, inside `performSetUp`'s `serviceProvider` closure (~line 440), change:

```swift
                    if settings.deepgramEnabled, keychain.get("deepgramAPIKey") != nil {
```

to:

```swift
                    if settings.transcriptionEngine == .deepgram, keychain.get("deepgramAPIKey") != nil {
```

And at the launch-drain gate (~line 566), change:

```swift
            let hasDeepgramKey = settings.deepgramEnabled && keychain.get("deepgramAPIKey") != nil
```

to:

```swift
            let hasDeepgramKey = settings.transcriptionEngine == .deepgram && keychain.get("deepgramAPIKey") != nil
```

Behavior-preserving substitution: Deepgram still requires both the user's choice and a keychain key, resolved fresh per job.

- [ ] **Step 5: Run the full test suite**

Run: `xcodebuild test -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone Air' 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **` with `transcriptionEngineMigratesFromLegacyToggle` passing.

- [ ] **Step 6: Commit**

```bash
git add Sotto/Files/RetentionPolicy.swift Sotto/App/AppModel.swift SottoTests/RetentionTests.swift
git commit -m "feat: enum-backed transcription engine setting with legacy toggle migration

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: Launch diagnostics for the persistence mystery

**Files:**
- Modify: `Sotto/App/AppModel.swift` (one log line in `performSetUp`)

**Interfaces:**
- Consumes: `SettingsStore.transcriptionEngine: TranscriptionBackend` (Task 1); `SettingsStore.defaults` (internal `let`, same module).
- Produces: no API — one os.Logger line, subsystem `com.decanlys.Sotto`, category `Settings`.

- [ ] **Step 1: Add the launch diagnostics log**

In `Sotto/App/AppModel.swift`: first check the imports at the top of the file; if `import os` is not present, add it (alphabetical order with the existing imports).

Then, directly ABOVE the `let hasDeepgramKey = settings.transcriptionEngine == .deepgram && ...` line (edited in Task 1, ~line 566), insert:

```swift
            // M10 diagnostics for the reported "Deepgram toggle reset itself" mystery
            // (2026-07-05: observed on simulator relaunches; key survived, onboarding did
            // not reappear, so the defaults plist was NOT wiped). Logs the raw stored
            // values every launch so the next occurrence is checkable in Console.app
            // (subsystem com.decanlys.Sotto, category Settings) instead of unreproducible.
            Logger(subsystem: "com.decanlys.Sotto", category: "Settings").info(
                "launch engine=\(settings.transcriptionEngine.rawValue, privacy: .public) rawNew=\(settings.defaults.string(forKey: "transcriptionEngine") ?? "nil", privacy: .public) rawLegacy=\(String(describing: settings.defaults.object(forKey: "deepgramEnabled") ?? "nil"), privacy: .public) hasKey=\(keychain.get("deepgramAPIKey") != nil)")
```

Placement note: `keychain` (`let keychain = KeychainStore()`, ~line 434) is already in scope there — that's why the log sits next to the `hasDeepgramKey` line rather than at the top of `performSetUp`.

- [ ] **Step 2: Build + run tests**

Run: `xcodebuild test -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone Air' 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **`, zero new warnings.

- [ ] **Step 3: Commit**

```bash
git add Sotto/App/AppModel.swift
git commit -m "feat: launch diagnostics for transcription engine persistence

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: Settings UI — engine Picker

**Files:**
- Modify: `Sotto/App/SettingsView.swift` (state, `.task` load, `transcriptionSection`)

**Interfaces:**
- Consumes: `SettingsStore.transcriptionEngine: TranscriptionBackend` (Task 1); existing `model.assetState`, `model.testDeepgramKey(_:)`, `KeychainStore`.
- Produces: UI only.

- [ ] **Step 1: Replace the toggle state with engine state**

In `Sotto/App/SettingsView.swift`, change line 14:

```swift
    @State private var deepgramEnabled = false
```

to:

```swift
    @State private var engine: TranscriptionBackend = .speechAnalyzer
```

and in the `.task` block, change line 38:

```swift
            deepgramEnabled = settings.deepgramEnabled
```

to:

```swift
            engine = settings.transcriptionEngine
```

- [ ] **Step 2: Replace the toggle with a Picker in `transcriptionSection`**

Replace the entire `transcriptionSection` computed property (lines 78–117) with:

```swift
    private var transcriptionSection: some View {
        Section("Transcription") {
            // M10: engine choice is a Picker, not a toggle — the setting is a selection
            // between engines (and leaves room for more), not an on/off feature.
            Picker("Engine", selection: $engine) {
                Text("On-device").tag(TranscriptionBackend.speechAnalyzer)
                Text("Deepgram (cloud)").tag(TranscriptionBackend.deepgram)
            }
            .onChange(of: engine) { _, value in model.settings.transcriptionEngine = value }
            HStack {
                Label("On-device model", systemImage: "iphone")
                Spacer()
                switch model.assetState {
                case .installed: Text("Installed").foregroundStyle(.secondary)
                case .downloading(let fraction): ProgressView(value: fraction).frame(width: 80)
                case .unsupported: Text("Unavailable on this device").foregroundStyle(.secondary)
                default: Button("Download") { Task { await model.downloadSpeechModel() } }
                }
            }
            if engine == .deepgram {
                SecureField("Deepgram API key", text: $deepgramKey)
                    .onChange(of: deepgramKey) { _, _ in keyTestResult = nil }
                    .onSubmit { persistKey() }
                HStack {
                    Button("Test key") {
                        Task {
                            persistKey()   // testing an untyped-submitted key must still work
                            keyTestResult = await model.testDeepgramKey(deepgramKey)
                        }
                    }
                    .disabled(deepgramKey.isEmpty)
                    if let result = keyTestResult {
                        Image(systemName: result ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(result ? .green : .red)
                    }
                }
                if deepgramKey.isEmpty {
                    // Surfaces the runtime's silent fallback (AppModel's provider requires a
                    // key) — without this the picker would look like it's doing something
                    // that it isn't.
                    Label("No API key — on-device transcription is used until a key is added.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
                Toggle("Wi-Fi only uploads", isOn: $wifiOnly)
                    .onChange(of: wifiOnly) { _, value in model.settings.wifiOnlyUpload = value }
                Text("~$0.26/hr, ~$0.38/hr with diarization, billed to your Deepgram account.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Audio is sent to Deepgram under your account; training opt-out is always sent.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
```

Notes for the implementer:
- The on-device model status row stays visible under BOTH selections — it's also the fallback engine when Deepgram has no key, so its install state always matters.
- Everything inside `if engine == .deepgram` other than the new empty-key warning is the existing code verbatim — do not restyle it.

- [ ] **Step 3: Build + full test suite**

Run: `xcodebuild test -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone Air' 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **`, zero new warnings.

- [ ] **Step 4: Manual verification in the simulator**

Run the app (`xcodebuild -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone Air' build` then launch via Simulator, or run from Xcode). Verify:
1. Settings → Transcription shows the Picker with "On-device" selected on a fresh install.
2. Selecting "Deepgram (cloud)" reveals key field + warning label (no key yet), Wi-Fi toggle, cost captions.
3. Kill and relaunch: the Picker selection persists.
4. Console.app filtered to subsystem `com.decanlys.Sotto` category `Settings` shows the launch line with `engine=`, `rawNew=`, `rawLegacy=`, `hasKey=`.

- [ ] **Step 5: Commit**

```bash
git add Sotto/App/SettingsView.swift
git commit -m "feat: transcription engine picker replaces Deepgram toggle

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

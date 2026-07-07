# M6a — UI Plumbing + Real Main Screen Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** First half of spec milestone M6: the data/plumbing the screens need (queue `retry` + hot-swappable backend, expanded user settings feeding `RecorderConfig`, speech-asset installer with progress) and the spec's real Main screen replacing the debug UI. (M6b — a separate plan — delivers List/Detail/Settings/Onboarding.)

**Architecture:** `TranscriptionQueue` swaps its fixed service for a `@Sendable () -> any TranscriptionService` provider (evaluated per job — backend changes apply to future segments per spec) and gains `retry(jobID:)`. `SettingsStore` grows the four listening parameters (spec's power-user table) + `deepgramEnabled`/`wifiOnlyUpload`; AppModel builds `RecorderConfig` and the detector threshold from it at setup (changes apply on next Start, per spec "changes affect only future segments"). `SpeechAssetInstaller` wraps `AssetInventory.assetInstallationRequest` behind a seam; AppModel exposes an `AssetState` and kicks the queue when installation completes. The Main screen implements the spec's states: dial + Start/Stop, today summary, battery hint, mic-permission-denied with Settings deep link, model-download progress, disk-guard + post-crash banners.

**Tech Stack:** SwiftUI (stock, system colors/typography per spec), Speech (AssetInventory), Swift 6 strict concurrency, Swift Testing.

## Global Constraints

- Test command: `xcodebuild test -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone Air' 2>&1 | tail -5` → `** TEST SUCCEEDED **` (slow; Busy → `xcrun simctl shutdown all`, retry). New files → `xcodegen generate`. Zero Swift warnings (appintents exempt). Swift 6, `SWIFT_DEFAULT_ACTOR_ISOLATION: nonisolated`.
- Spec bindings: settings ranges/defaults verbatim — VAD threshold 0.6 (0.1–0.9), silence timeout 45 s (15–120), ring buffer 1.0 s (0.5–3.0), min segment 3 s (1–10); backend change "affects only future segments"; UI = stock SwiftUI, Dark-Mode + accessibility-size safe, no third-party UI; Main screen purpose "one glance = current state; one tap = start/stop"; mic-denied state disables Start and deep-links to Settings; model-downloading state disables Start with copy "Preparing on-device transcription…"; unit tests must never trigger real asset downloads (the installer is only exercised through a fake).
- Existing contracts survive (pipeline invariants, queue drain semantics incl. environmental classification, salvage-before-queue, index wiring).
- Commits end with:

  Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>

## File Structure

```
Sotto/Transcription/TranscriptionQueue.swift  ← retry(jobID:), serviceProvider (modify)
Sotto/Files/RetentionPolicy.swift             ← SettingsStore expansion (modify)
Sotto/Transcription/SpeechAssetInstaller.swift ← seam + AssetInventory impl (new)
Sotto/App/AppModel.swift                      ← settings→config, assetState, wiring (modify)
Sotto/App/ContentView.swift                   ← real Main screen (rewrite)
SottoTests/TranscriptionQueueTests.swift, RetentionTests.swift, AppModelTests.swift, Fakes.swift (modify)
```

---

### Task 1: Queue `retry(jobID:)` + service provider

**Files:**
- Modify: `Sotto/Transcription/TranscriptionQueue.swift`, `Sotto/App/AppModel.swift` (call-site), `SottoTests/TranscriptionQueueTests.swift`, `SottoTests/Fakes.swift`

**Interfaces:**
- Produces:

```swift
// init changes: service: any TranscriptionService  →  serviceProvider: @escaping @Sendable () -> any TranscriptionService
// (add a convenience init(service:) that wraps it, so existing tests keep compiling:
//  init(storeURL:service:maxAttempts:rootDirectory:) { self.init(storeURL:, serviceProvider: { service }, ...) })
/// Failed-row retry (SPEC detail/list views): resets a .failed job to .pending with
/// attempts 0 and kicks a drain.
func retry(jobID: UUID) async
```

The worker resolves `serviceProvider()` freshly per job inside `step` — a backend change (Deepgram key added, M6b settings) applies to all FUTURE jobs without queue reconstruction, per spec "changes affect only future segments".

- [ ] **Step 1: Failing tests (append to TranscriptionQueueTests):**

```swift
    @Test func retryResetsFailedJobAndDrains() async throws {
        let dir = tempDir()
        let flaky = FakeTranscriptionService(text: "second time lucky", failuresBeforeSuccess: 1)
        let queue = TranscriptionQueue(
            storeURL: dir.appendingPathComponent("jobs.json"),
            service: flaky, maxAttempts: 1, rootDirectory: dir)
        await queue.enqueue(try makeSegment(in: dir.appendingPathComponent("a")))
        await queue.drain()
        let failed = await queue.jobs.first
        #expect(failed?.state == .failed)

        await queue.retry(jobID: failed!.id)

        #expect(await queue.jobs.first?.state == .done)   // retry re-drained and succeeded
        #expect(await queue.jobs.first?.attempts == 0 || (await queue.jobs.first?.state == .done))
    }

    @Test func serviceProviderIsEvaluatedPerJob() async throws {
        let dir = tempDir()
        let selector = Mutex<String>("first")
        let queue = TranscriptionQueue(
            storeURL: dir.appendingPathComponent("jobs.json"),
            serviceProvider: {
                FakeTranscriptionService(text: selector.withLock { $0 })
            },
            rootDirectory: dir)
        await queue.enqueue(try makeSegment(in: dir.appendingPathComponent("a")))
        await queue.drain()
        selector.withLock { $0 = "second" }
        await queue.enqueue(try makeSegment(in: dir.appendingPathComponent("b")))
        await queue.drain()

        let dirA = dir.appendingPathComponent("a/seg.md")
        let dirB = dir.appendingPathComponent("b/seg.md")
        #expect(try String(contentsOf: dirA, encoding: .utf8).contains("first"))
        #expect(try String(contentsOf: dirB, encoding: .utf8).contains("second"))
    }
```

(`import Synchronization` if not present. NOTE: `FakeTranscriptionService` is an actor — if constructing it inside a non-async closure fails, give the provider test a tiny struct fake instead: `struct FixedTextService: TranscriptionService { let backend = TranscriptionBackend.speechAnalyzer; let text: String; func transcribe(file: URL) async throws -> TranscriptionResult { TranscriptionResult(text: text, segments: [], duration: 1, backend: backend) } }` in Fakes.swift — record which you used.)

- [ ] **Step 2: RED → implement.** Queue: replace `private let service` with `private let serviceProvider: @Sendable () -> any TranscriptionService`; designated init takes `serviceProvider`; add convenience `init(storeURL:service:maxAttempts:rootDirectory:)` forwarding `{ service }` so all existing call sites/tests compile unchanged. In `step`'s phase 2: `let service = serviceProvider()` then use it. Add:

```swift
    func retry(jobID: UUID) async {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }),
              jobs[index].state == .failed else { return }
        jobs[index].state = .pending
        jobs[index].attempts = 0
        persist()
        await drain()
    }
```

AppModel: switch construction to `TranscriptionQueue(serviceProvider: { ... })` — move the existing backend-selection if/else INTO the closure (evaluating `KeychainStore().get("deepgramAPIKey")` per job — that is the hot-swap): keep the launch-gate logic reading the same conditions once outside (unchanged behavior).

- [ ] **Step 3: GREEN, commit:** `git add Sotto SottoTests && git commit -m "feat: queue retry API and per-job backend selection"`

---

### Task 2: SettingsStore expansion + AppModel config plumbing

**Files:**
- Modify: `Sotto/Files/RetentionPolicy.swift` (SettingsStore lives here), `Sotto/App/AppModel.swift`, `SottoTests/RetentionTests.swift`

**Interfaces:**
- Produces (M6b's Settings screen binds to these; ranges are UI-enforced there):

```swift
// SettingsStore additions (all UserDefaults-backed, same nonmutating-set pattern):
var vadThreshold: Float          // default 0.6
var silenceTimeout: TimeInterval // default 45
var minSegmentSpeech: TimeInterval // default 3
var preRollSeconds: TimeInterval // default 1.0
var wifiOnlyUpload: Bool         // default true (consumed by M6b's network gate)
var deepgramEnabled: Bool        // default false (M6b settings toggle; Task 1's provider
                                 //   already requires a key — this adds the explicit toggle)
```

AppModel: `RecorderConfig` built from settings at `performSetUp` (silenceTimeout, minSegmentSpeechDuration, preRollCapacity = `Int(settings.preRollSeconds * Double(VADConstants.sampleRate))`), detector threshold = `settings.vadThreshold`; the Task 1 service-provider closure additionally requires `settings.deepgramEnabled` before choosing Deepgram. Settings changes apply on the NEXT Start/launch (spec: future segments only) — add that sentence as a doc comment on the SettingsStore extension.

- [ ] **Step 1: Failing test (append to RetentionTests):**

```swift
    @Test func listeningSettingsDefaultsMatchSpec() {
        let suite = UserDefaults(suiteName: "settings-tests-\(UUID().uuidString)")!
        let settings = SettingsStore(defaults: suite)
        #expect(settings.vadThreshold == 0.6)
        #expect(settings.silenceTimeout == 45)
        #expect(settings.minSegmentSpeech == 3)
        #expect(settings.preRollSeconds == 1.0)
        #expect(settings.wifiOnlyUpload == true)
        #expect(settings.deepgramEnabled == false)
        settings.vadThreshold = 0.4
        settings.silenceTimeout = 90
        #expect(settings.vadThreshold == Float(0.4))
        #expect(settings.silenceTimeout == 90)
    }
```

- [ ] **Step 2: RED → implement.** SettingsStore getters use `object(forKey:) == nil ? default : typed read` (NOT `double(forKey:)` alone — it returns 0 for missing keys; pattern: `defaults.object(forKey: "vadThreshold") == nil ? 0.6 : defaults.float(forKey: "vadThreshold")`). AppModel `performSetUp`: build `var config = RecorderConfig(); config.silenceTimeout = settings.silenceTimeout; config.minSegmentSpeechDuration = settings.minSegmentSpeech; config.preRollCapacity = max(1, Int(settings.preRollSeconds * Double(VADConstants.sampleRate)))` and pass `config` to `RecorderStateMachine(...)`; construct the detector with `threshold: settings.vadThreshold`; extend the provider closure: `if settings.deepgramEnabled, keychain.get("deepgramAPIKey") != nil { Deepgram } else { SpeechAnalyzer }` (and mirror in the launch-gate condition: `hasDeepgramKey` becomes `settings.deepgramEnabled && key != nil`).

- [ ] **Step 3: GREEN, commit:** `git add Sotto SottoTests && git commit -m "feat: listening settings feed recorder config and backend selection"`

---

### Task 3: SpeechAssetInstaller seam + AppModel asset state

**Files:**
- Create: `Sotto/Transcription/SpeechAssetInstaller.swift`
- Modify: `Sotto/App/AppModel.swift`, `SottoTests/Fakes.swift`, `SottoTests/AppModelTests.swift`

**Interfaces:**
- Produces:

```swift
protocol SpeechAssetInstalling: Sendable {
    func assetsInstalled() async -> Bool
    /// Requests + downloads the speech model for the current locale, reporting 0…1.
    /// Throws on failure (incl. offline-at-first-run — SPEC requires explicit handling).
    func install(progress: @escaping @Sendable (Double) -> Void) async throws
}

struct SpeechAssetInstaller: SpeechAssetInstalling {
    let locale: Locale   // init(locale: Locale = .current)
}

// AppModel:
enum AssetState: Equatable { case unknown, installed, notInstalled, downloading(Double), failed(String) }
private(set) var assetState: AssetState   // resolved during performSetUp
func downloadSpeechModel() async          // notInstalled/failed → downloading → installed (+ drain kick)
```

- [ ] **Step 1: Implement `Sotto/Transcription/SpeechAssetInstaller.swift`:**

```swift
import Foundation
import Speech

protocol SpeechAssetInstalling: Sendable {
    func assetsInstalled() async -> Bool
    func install(progress: @escaping @Sendable (Double) -> Void) async throws
}

/// AssetInventory wrapper (SPEC "Model assets"): models are system-shared and often
/// pre-installed (Notes uses them) but never guaranteed. NEVER called from unit tests —
/// downloads are real; the app calls it from the Main screen / onboarding flow.
struct SpeechAssetInstaller: SpeechAssetInstalling {
    enum InstallerError: Error { case unsupportedDevice, noRequestNeededButStillMissing }

    let locale: Locale

    init(locale: Locale = .current) {
        self.locale = locale
    }

    func assetsInstalled() async -> Bool {
        await SpeechAnalyzerService.assetsInstalled(for: locale)
    }

    func install(progress: @escaping @Sendable (Double) -> Void) async throws {
        guard SpeechTranscriber.isAvailable else { throw InstallerError.unsupportedDevice }
        let base = SpeechTranscriber.Preset.transcription
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: base.transcriptionOptions,
            reportingOptions: base.reportingOptions,
            attributeOptions: base.attributeOptions)
        guard let request = try await AssetInventory.assetInstallationRequest(
            supporting: [transcriber]) else {
            // Nothing to install — either already present, or the locale is unsupported.
            if await assetsInstalled() { return }
            throw InstallerError.noRequestNeededButStillMissing
        }
        // Progress observation: AssetInstallationRequest exposes `progress` (Foundation
        // Progress). Poll it while downloadAndInstall() runs. ADAPT-ALLOWED: if the SDK
        // exposes a different member name, grep the Speech swiftinterface for
        // "AssetInstallationRequest" and adapt, recording the deviation.
        let observation = Task {
            while !Task.isCancelled {
                progress(request.progress.fractionCompleted)
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        defer { observation.cancel() }
        try await request.downloadAndInstall()
        progress(1.0)
    }
}
```

- [ ] **Step 2: Fake + AppModel wiring.** `FakeAssetInstaller` in Fakes.swift:

```swift
actor FakeAssetInstaller: SpeechAssetInstalling {
    var installed: Bool
    var installError: Error?
    private(set) var installCalls = 0

    init(installed: Bool = false) {
        self.installed = installed
    }

    func assetsInstalled() -> Bool { installed }

    func install(progress: @escaping @Sendable (Double) -> Void) async throws {
        installCalls += 1
        if let installError { throw installError }
        progress(0.5)
        installed = true
        progress(1.0)
    }

    func setError(_ error: Error?) { installError = error }
}
```

AppModel: `private(set) var assetState: AssetState = .unknown`; init param `assetInstaller: (any SpeechAssetInstalling)? = nil` (defaults to `SpeechAssetInstaller()` lazily in performSetUp so tests inject the fake); in `performSetUp`, replace the bare `SpeechAnalyzerService.assetsInstalled` call with the installer: `let onDeviceReady = await installer.assetsInstalled(); assetState = onDeviceReady ? .installed : .notInstalled` (keep the launch-gate + notice logic driven by `onDeviceReady`). Add:

```swift
    func downloadSpeechModel() async {
        guard case .notInstalled = assetState else {
            if case .failed = assetState { /* retry allowed */ } else { return }
        }
        assetState = .downloading(0)
        do {
            try await installer.install { [weak self] fraction in
                Task { @MainActor [weak self] in
                    if case .downloading = self?.assetState { self?.assetState = .downloading(fraction) }
                }
            }
            assetState = .installed
            if let queue { Task { await queue.drain() } }   // pending jobs can proceed now
        } catch {
            assetState = .failed(String(describing: error))
        }
    }
```

(NOTE the guard: allow entry from `.notInstalled` OR `.failed` — write it as a `switch` for clarity; the snippet's guard-shape is awkward, implement as `switch assetState { case .notInstalled, .failed: break; default: return }`. AppModel stores `installer` as a property resolved at init: `self.installer = assetInstaller ?? SpeechAssetInstaller()`. `queue` must be readable — it already is a stored property.)

- [ ] **Step 3: Tests (append to AppModelTests):**

```swift
    @Test func downloadSpeechModelTransitionsThroughStates() async throws {
        let installer = FakeAssetInstaller(installed: false)
        let model = AppModel(assetInstaller: installer)
        await model.ensureSetUp()
        #expect(model.assetState == .notInstalled)

        await model.downloadSpeechModel()

        #expect(model.assetState == .installed)
        #expect(await installer.installCalls == 1)
    }

    @Test func downloadFailureLandsInFailedAndAllowsRetry() async throws {
        struct Boom: Error {}
        let installer = FakeAssetInstaller(installed: false)
        await installer.setError(Boom())
        let model = AppModel(assetInstaller: installer)
        await model.ensureSetUp()
        await model.downloadSpeechModel()
        if case .failed = model.assetState {} else { Issue.record("expected .failed") }

        await installer.setError(nil)
        await model.downloadSpeechModel()
        #expect(model.assetState == .installed)
    }
```

CAUTION: `AppModel.ensureSetUp()` runs the FULL setup (CoreML load, salvage, engine construction — but not engine START). In the test host this loads the real bundled VAD model — that already happens in other tests and is fast; acceptable. If `ensureSetUp` fails in the test host for an environmental reason, report it — do not stub around it silently. Also note AppModel registers the intent handler; with Fix-4-era ownership semantics the FIRST test-created model claims it — harmless (documented in the earlier test file).

- [ ] **Step 4: GREEN, commit:** `git add Sotto SottoTests && git commit -m "feat: speech asset installer seam with download state machine"`

---

### Task 4: Real Main screen

**Files:**
- Modify: `Sotto/App/ContentView.swift` (full rewrite below)
- Test: build + full suite (UI logic is thin; state mapping is exercised through the pipeline/model tests) + e2e screenshot

**Interfaces:**
- Consumes: everything. The debug event-log list is REPLACED by the spec Main screen; `pipeline.eventLog` stays available (M6b's screens may surface pieces).

- [ ] **Step 1: Rewrite `Sotto/App/ContentView.swift`:**

```swift
import AVFAudio
import SwiftUI
import UIKit

/// SPEC "Main screen": one glance = current state; one tap = start/stop.
struct ContentView: View {
    let model: AppModel
    @State private var micDenied = false

    var body: some View {
        NavigationStack {
            Group {
                if let setupError = model.setupError {
                    ContentUnavailableView(
                        "Setup failed",
                        systemImage: "exclamationmark.triangle",
                        description: Text(setupError))
                } else if let pipeline = model.pipeline {
                    MainScreen(model: model, pipeline: pipeline, micDenied: micDenied)
                } else {
                    ProgressView("Preparing…")
                }
            }
            .navigationTitle("Sotto")
        }
        .task {
            await model.ensureSetUp()
            micDenied = AVAudioApplication.shared.recordPermission == .denied
        }
    }
}

private struct MainScreen: View {
    let model: AppModel
    let pipeline: ListeningPipeline
    let micDenied: Bool

    private var isActive: Bool { pipeline.status != .idle }

    var body: some View {
        VStack(spacing: 20) {
            banners
            StateDial(status: pipeline.status)
            Text(stateLabel)
                .font(.title.bold())
                .foregroundStyle(stateColor)

            todaySummary

            startStopButton

            if isActive {
                Text("Listening uses roughly as much battery as music playback.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 12)
    }

    @ViewBuilder
    private var banners: some View {
        if let notice = model.recoveryNotice {
            NoticeBanner(text: notice, color: .orange)
        }
        if case .downloading(let fraction) = model.assetState {
            VStack(spacing: 4) {
                ProgressView(value: fraction)
                Text("Preparing on-device transcription…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)
        } else if case .notInstalled = model.assetState {
            Button {
                Task { await model.downloadSpeechModel() }
            } label: {
                Label("Download transcription model", systemImage: "arrow.down.circle")
                    .font(.footnote)
            }
        } else if case .failed(let message) = model.assetState {
            VStack(spacing: 4) {
                NoticeBanner(text: "Model download failed — check your connection.", color: .red)
                Button("Try again") { Task { await model.downloadSpeechModel() } }
                    .font(.footnote)
            }
            .accessibilityHint(Text(message))
        }
        if micDenied {
            VStack(spacing: 6) {
                NoticeBanner(
                    text: "Microphone access is off. Sotto can't listen without it.",
                    color: .red)
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .font(.footnote.bold())
            }
        }
        if let last = pipeline.eventLog.last, last.contains("Low disk space") {
            NoticeBanner(text: "Low disk space — new recordings are paused.", color: .red)
        }
    }

    private var todaySummary: some View {
        Group {
            if let summary = model.todaySummary {
                Text("\(summary.count) conversations · \(Int(summary.totalMinutes)) min")
            } else {
                Text("No conversations yet today")
            }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .task(id: pipeline.finalizedCount) {
            await model.refreshTodaySummary()
        }
    }

    private var startStopButton: some View {
        Button {
            Task {
                switch pipeline.status {
                case .idle: await pipeline.start()
                case .interrupted: await pipeline.resumeFromInterruption()
                default: await pipeline.stop()
                }
            }
        } label: {
            Text(buttonLabel)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .tint(isActive ? .red : .accentColor)
        .padding(.horizontal, 40)
        .disabled(micDenied && pipeline.status == .idle)
    }

    private var buttonLabel: String {
        switch pipeline.status {
        case .idle: "Start Listening"
        case .interrupted: "Resume"
        default: "Stop"
        }
    }

    private var stateLabel: String {
        switch pipeline.status {
        case .idle: "Idle"
        case .starting: "Starting…"
        case .listening: "Listening"
        case .recording: "Recording"
        case .silence: "Listening"
        case .interrupted: pipeline.haltReason == .userPause ? "Paused by you" : "Paused — call"
        }
    }

    private var stateColor: Color {
        switch pipeline.status {
        case .idle: .secondary
        case .starting: .secondary
        case .listening, .silence: .green
        case .recording: .red
        case .interrupted: .orange
        }
    }
}

/// The spec's "large state dial": a pulsing ring while listening, solid otherwise.
private struct StateDial: View {
    let status: ListeningPipeline.Status
    @State private var pulsing = false

    private var color: Color {
        switch status {
        case .idle, .starting: .secondary.opacity(0.4)
        case .listening, .silence: .green
        case .recording: .red
        case .interrupted: .orange
        }
    }

    private var isLive: Bool {
        switch status {
        case .listening, .recording, .silence: true
        default: false
        }
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(color, lineWidth: 6)
                .frame(width: 140, height: 140)
                .scaleEffect(pulsing && isLive ? 1.06 : 1.0)
                .animation(
                    isLive ? .easeInOut(duration: 1.2).repeatForever(autoreverses: true) : .default,
                    value: pulsing && isLive)
            Image(systemName: status == .recording ? "waveform" : "mic")
                .font(.system(size: 44))
                .foregroundStyle(color)
        }
        .onAppear { pulsing = true }
        .accessibilityHidden(true)
    }
}

private struct NoticeBanner: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(color)
            .multilineTextAlignment(.center)
            .padding(.horizontal)
    }
}
```

- [ ] **Step 2: AppModel additions for the summary:**

```swift
    struct TodaySummary: Equatable {
        let count: Int
        let totalMinutes: Double
    }
    private(set) var todaySummary: TodaySummary?

    func refreshTodaySummary() async {
        guard let dayIndex else { return }
        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.calendar = Calendar(identifier: .gregorian)
        dayFormatter.dateFormat = "yyyy-MM-dd"
        let dayDirectory = segmentRoot.appendingPathComponent(dayFormatter.string(from: Date()))
        guard let index = await dayIndex.index(forDay: dayDirectory), !index.segments.isEmpty else {
            todaySummary = nil
            return
        }
        todaySummary = TodaySummary(
            count: index.segments.count,
            totalMinutes: index.segments.reduce(0) { $0 + $1.duration } / 60)
    }
```

(store `segmentRoot` = `store.rootDirectory` as a stored property during performSetUp: `private var segmentRoot: URL = ...` — assign where `store` is created.)

- [ ] **Step 3: Full suite green (no test-count change expected), then e2e:** build, install, launch on iPhone Air; screenshot to the session scratchpad; verify: dial + Idle, "Download transcription model" button visible (assets absent on sim), summary line, Start enabled. Commit:

```bash
git add Sotto/App && git commit -m "feat: spec main screen with dial, banners, summary, and asset download"
```

## Self-review notes

- Spec Main-screen coverage: dial+animation ✓; Start/Stop prominent ✓; today summary ✓ (tap→List is M6b — the NavigationLink lands there with the list screen); battery hint ✓; mic-denied (explainer + Open Settings + Start disabled) ✓; model-downloading (progress + "Preparing on-device transcription…" + Start… spec says Start disabled while downloading — the download runs alongside idle Start; SPEC's intent is transcription-not-ready; recording without transcription is VALID in this design (queue holds jobs) — deviation NOTED: Start stays enabled while downloading because recordings queue safely; flag to the reviewer for adjudication rather than silently matching or diverging); disk-guard banner ✓; post-crash banner ✓.
- Dark mode + accessibility: system colors/fonts only; dial is accessibilityHidden with the text label carrying state.
- Type consistency: `AssetState` switch coverage in banners matches Task 3's enum; `TodaySummary` naming consistent; Task 1's convenience init keeps every existing test compiling.

# M4 — Transcription Queue + SpeechAnalyzer + Deepgram Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement spec milestone M4 — a persisted, serial transcription queue fed by the recorder, with `SpeechAnalyzerService` (on-device, default) and `DeepgramService` (BYOK cloud) — leading with the two M3-review Criticals as Tasks 1–2: segment finalize becomes fast (close CAF, transcode deferred to the queue), and the app gains a scene-independent `AppModel` so the Live Activity intent works on cold background launches.

**Architecture:** `SegmentWriting.finalize()` (which transcoded synchronously — a watchdog-kill risk inside the ~30 s interruption window) splits into `close()` (fast, CAF stays on disk) + deferred transcode inside the `TranscriptionQueue` actor's serial worker (transcode → transcribe → write `.md` → delete CAF). The queue persists `jobs.json` atomically and self-heals with the launch salvage sweep (if salvage already transcoded a job's CAF, the worker skips to transcription). `AppModel` (@MainActor @Observable, created in `SottoApp`) owns setup/pipeline/queue and registers an intent handler in a dependency-free shared registry, replacing the NotificationCenter bridge — `perform()` now awaits the real toggle, keeping the background-launched process alive. The lock-screen button becomes a true PAUSE ("Paused by you", activity survives) rather than a stop.

**Tech Stack:** Speech framework (SpeechAnalyzer/SpeechTranscriber — API verified against the iOS 26.5 SDK), URLSession (+URLProtocol test mocks), Security (Keychain), Swift 6 strict concurrency, Swift Testing, XcodeGen.

## Global Constraints

- Test command (every task): `xcodebuild test -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone Air' 2>&1 | tail -5` → `** TEST SUCCEEDED **`. Slow, not hung. Simulator Busy → `xcrun simctl shutdown all`, retry.
- New files → `xcodegen generate` first. Zero Swift warnings (`grep "warning:" <log> | grep -v appintents` → empty).
- Swift 6, `SWIFT_DEFAULT_ACTOR_ISOLATION: nonisolated`.
- Spec bindings (docs/SPEC.md "Transcription layer"): **transcription is a persisted queue, never inline**; serial worker drains whenever the app runs; leftover jobs drain on next resume/foreground. SpeechAnalyzer: custom preset = `.transcription` + `.audioTimeRange`, **no speech-recognition permission exists — never add one**; runtime `isAvailable` gate. Deepgram: `POST https://api.deepgram.com/v1/listen` with `model=nova-3&diarize_model=latest&utterances=true&smart_format=true&mip_opt_out=true` (NEVER also `diarize=true`), body = m4a binary, key in **Keychain**, BYOK.
- Verified SDK facts (do not re-derive): `SpeechTranscriber(locale:transcriptionOptions:reportingOptions:attributeOptions:)`; `SpeechTranscriber.Preset.transcription` (`.transcriptionOptions/.reportingOptions/.attributeOptions` are `var`s on Preset); `ResultAttributeOption.audioTimeRange`; `static var isAvailable: Bool`; `static var installedLocales: [Locale]` (async? it's a static property — check call site; if `get async`, `await` it); `results: AsyncSequence<SpeechTranscriber.Result, Error>`; `SpeechAnalyzer(modules:options:)`; `analyzeSequence(from: AVAudioFile) -> CMTime?`; `finalizeAndFinishThroughEndOfInput()`; `AssetInventory.assetInstallationRequest(supporting:) -> AssetInstallationRequest?`.
- Adapt-allowed zone (record deviations): the exact extraction of per-result text/time attributes from `SpeechTranscriber.Result` (AttributedString runs) — adapt to the SDK, keep the `TranscriptionSegment` contract.
- Unit tests must NEVER trigger asset downloads (`assetInstallationRequest`) — SpeechAnalyzer tests skip gracefully when the model/locale isn't installed on the simulator.
- Existing contracts survive: all pipeline transition invariants; recorder semantics except the finalize split; salvage sweep; heartbeat.
- Commits end with:

  Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>

## File Structure

```
Sotto/Segments/SegmentWriting.swift        ← close() replaces finalize(); FinalizedSegment gains cafURL (modify)
Sotto/Segments/CAFSegmentWriter.swift      ← close() impl; transcode stays as static (modify)
Sotto/Recorder/RecorderStateMachine.swift  ← finalizeSegment uses close() (modify)
Sotto/Transcription/TranscriptionService.swift  ← protocol + result types (spec)
Sotto/Transcription/TranscriptionQueue.swift    ← persisted serial queue actor
Sotto/Transcription/TranscriptMarkdownWriter.swift ← .md rendering (spec format)
Sotto/Transcription/SpeechAnalyzerService.swift
Sotto/Transcription/DeepgramService.swift
Sotto/Transcription/KeychainStore.swift
Sotto/App/AppModel.swift                   ← scene-independent owner (moves setUp out of ContentView)
Sotto/App/SottoApp.swift, ContentView.swift ← slim (modify)
Sotto/LiveActivity/ToggleListeningIntent.swift ← awaits IntentHandlers.shared.toggle (modify)
Sotto/Pipeline/ListeningPipeline.swift     ← pauseByUser + HaltReason + eventLog cap (modify)
SottoTests/TranscriptionQueueTests.swift, MarkdownWriterTests.swift, DeepgramServiceTests.swift,
SpeechAnalyzerServiceTests.swift, AppModelTests.swift (new); Fakes.swift, RecorderStateMachineTests.swift,
RecorderIntegrationTests.swift, InterruptionTests.swift (modify)
```

---

### Task 1: Finalize split — fast close(), transcode deferred (M3 Critical #1)

**Files:**
- Modify: `Sotto/Segments/SegmentWriting.swift`
- Modify: `Sotto/Segments/CAFSegmentWriter.swift`
- Modify: `Sotto/Recorder/RecorderStateMachine.swift`
- Modify: `SottoTests/Fakes.swift` (FakeSegmentWriter)
- Test: `SottoTests/SegmentWriterTests.swift`, `SottoTests/RecorderStateMachineTests.swift`, `SottoTests/RecorderIntegrationTests.swift` (modify)

**Interfaces:**
- Produces (Tasks 3/6 rely on):

```swift
struct FinalizedSegment: Sendable, Equatable {
    let cafURL: URL              // closed capture file, still on disk
    let m4aURL: URL              // transcode DESTINATION (does not exist yet)
    let startDate: Date
    let duration: TimeInterval
    let speechDuration: TimeInterval
}

protocol SegmentWriting {
    var writtenSampleCount: Int { get }
    var cafURL: URL { get }
    var m4aURL: URL { get }
    func append(_ samples: [Float]) throws
    /// FAST: flush + release the file handle. The CAF stays on disk; transcode is the
    /// transcription queue's job (M3 review Critical #1: a synchronous transcode of a
    /// 2 h segment inside the ~30 s interruption window watchdog-kills the app).
    func close()
    func discard()
}
```

- [ ] **Step 1: Update the protocol + writer.** In `SegmentWriting.swift`: replace `finalize() throws -> URL` with `func close()`; add `var cafURL: URL { get }` / `var m4aURL: URL { get }`; add `cafURL` as the first field of `FinalizedSegment` with the doc comments above. In `CAFSegmentWriter.swift`: make the stored `cafURL`/`m4aURL` non-private (`let cafURL: URL` / `let m4aURL: URL`); replace `finalize()` with `func close() { file = nil }`; keep `discard()` and the static `transcodeToM4A` exactly as they are (salvage + queue both use it).

- [ ] **Step 2: Update the recorder.** In `RecorderStateMachine.swift` `finalizeSegment()`: the else-branch becomes non-throwing:

```swift
        closing.close()
        finalizedCount += 1
        lastEvent = "Saved conversation"
        let segment = FinalizedSegment(
            cafURL: closing.cafURL,
            m4aURL: closing.m4aURL,
            startDate: startDate,
            duration: secondsOf(closing.writtenSampleCount),
            speechDuration: speechDuration)
        segmentHandler?(segment)
```

(delete the `do/catch` — nothing throws now; keep the discard branch unchanged.)

- [ ] **Step 3: Update fakes + tests.** `FakeSegmentWriter`: add `let cafURL = URL(fileURLWithPath: "/tmp/fake-\(UUID().uuidString).caf")`, keep `m4aURL`, replace `finalize()` with `func close() { finalized = true }` (keep the `finalized` property name so most assertions survive). `SegmentWriterTests`: `finalizeProducesReadableM4AAndDeletesCAF` becomes `closeKeepsCAFOnDiskAndDeferredTranscodeProducesM4A`:

```swift
    @Test func closeKeepsCAFOnDiskAndDeferredTranscodeProducesM4A() throws {
        let (caf, m4a) = tempURLs()
        let writer = try CAFSegmentWriter(cafURL: caf, m4aURL: m4a)
        try writer.append(sineChunk(seconds: 1.0))
        writer.close()
        #expect(FileManager.default.fileExists(atPath: caf.path))     // close is NOT transcode
        #expect(!FileManager.default.fileExists(atPath: m4a.path))
        try CAFSegmentWriter.transcodeToM4A(caf: caf, m4a: m4a)       // the queue's job
        let file = try AVAudioFile(forReading: m4a)
        #expect(abs(Double(file.length) / file.processingFormat.sampleRate - 1.0) < 0.15)
    }
```

`RecorderStateMachineTests.segmentHandlerReceivesFinalizedSegment`: add `#expect(segments[0].cafURL.lastPathComponent.hasSuffix(".caf"))`. `RecorderIntegrationTests`: after finalize, assert the CAF exists and the m4a does NOT yet; then run `try CAFSegmentWriter.transcodeToM4A(caf:m4a:)` on the emitted segment (capture it via `setSegmentHandler` + `Mutex`) and keep the existing m4a-duration assertions; the "no CAF left behind" assertion moves to AFTER a manual `FileManager.default.removeItem(at: segment.cafURL)` (the queue owns deletion from Task 3 on — note this in a comment).

- [ ] **Step 4: `xcodegen generate` (no new files, skip), full suite green, commit:** `git add Sotto/Segments Sotto/Recorder SottoTests && git commit -m "feat: split segment finalize into fast close + deferred transcode"`

---

### Task 2: AppModel + awaited intent + "Paused by you" (M3 Critical #2, Important #4)

**Files:**
- Create: `Sotto/App/AppModel.swift`
- Modify: `Sotto/App/SottoApp.swift`, `Sotto/App/ContentView.swift`, `Sotto/LiveActivity/ToggleListeningIntent.swift`, `Sotto/Pipeline/ListeningPipeline.swift`
- Modify: `SottoTests/Fakes.swift`, `SottoTests/InterruptionTests.swift`
- Test: `SottoTests/AppModelTests.swift` (new)

**Interfaces:**
- Produces:

```swift
// In ToggleListeningIntent.swift (SHARED file — stays dependency-free):
@MainActor
final class IntentHandlers {
    static let shared = IntentHandlers()
    /// Registered by AppModel at construction; awaited by ToggleListeningIntent.perform().
    var toggle: (() async -> Void)?
}
// perform() becomes: `await IntentHandlers.shared.toggle?(); return .result()`
// (delete Notification.Name.sottoToggleListening and the post)

@MainActor @Observable
final class AppModel {
    private(set) var pipeline: ListeningPipeline?
    private(set) var setupError: String?
    private(set) var recoveryNotice: String?
    init()                       // registers IntentHandlers.shared.toggle
    func ensureSetUp() async     // sentinel-guarded; moved verbatim from ContentView.setUp
    func toggleFromIntent() async  // await ensureSetUp(); await pipeline?.toggleFromIntent()
}

// ListeningPipeline additions:
enum HaltReason: Sendable, Equatable { case systemInterruption, userPause }
private(set) var haltReason: HaltReason?      // non-nil only while .interrupted
func pauseByUser() async                       // park with reason .userPause: NO fallback
                                               // notification; activity label "Paused by you"
// toggleFromIntent(): idle → start; interrupted → resumeFromInterruption; else → pauseByUser()
// HaltMode becomes { stop, park(HaltReason) }; interrupt() == park(.systemInterruption).
// activityLabel becomes an instance method using haltReason for the interrupted case.
// eventLog capped at 200 entries in apply() (M2 carryover).
```

- [ ] **Step 1: Rework the shared intent file.** `ToggleListeningIntent.swift`: delete the `Notification.Name` extension and the post; add `IntentHandlers` (above — it is `@MainActor` and dependency-free, safe in the widget target where `toggle` is simply never registered); `perform()`:

```swift
    func perform() async throws -> some IntentResult {
        // Awaiting the real toggle keeps the background-launched app process alive until
        // the mic actually starts/stops (M3 review Critical #2: fire-and-forget posts are
        // dropped when no scene/observer exists on a cold background launch).
        await IntentHandlers.shared.toggle?()
        return .result()
    }
```

- [ ] **Step 2: Pipeline pause semantics.** In `ListeningPipeline.swift`: change `HaltMode` to `{ case stop; case park(HaltReason) }`; add `HaltReason` + stored `haltReason`. `performHalt(.park(reason))`: markInterrupted; `haltReason = reason`; eventLog + activity label from reason ("Paused — call" vs "Paused by you"); schedule the fallback notification ONLY for `.systemInterruption`. `interrupt()` calls `performHalt(.park(.systemInterruption))` (pendingInterrupt path likewise); new `pauseByUser()` mirrors `interrupt()` with `.park(.userPause)`. Clear `haltReason = nil` on resume success and in the `.stop` case. `activityLabel(for:)` becomes instance `activityLabel(for status: Status) -> String` using `haltReason` when `.interrupted` (default to "Paused — call" if nil). `toggleFromIntent()`: `default:` branch calls `pauseByUser()` instead of `stop()` (the in-app Stop button keeps calling `stop()`). In `apply()`, after appending to eventLog: `if eventLog.count > 200 { eventLog.removeFirst(eventLog.count - 200) }`. ContentView's `.interrupted` label: use `pipeline.haltReason == .userPause ? "Paused by you" : "Paused — call"` (both statusLabel and the Live Activity go through the pipeline's own label function).

- [ ] **Step 3: AppModel.** Create `Sotto/App/AppModel.swift`: move ContentView's ENTIRE `setUp()` body into `func ensureSetUp()` (same sentinel via a stored `private var setUpStarted = false`; `pipeline`/`setupError`/`recoveryNotice`/`observer` become AppModel properties). `init()` registers `IntentHandlers.shared.toggle = { [weak self] in await self?.toggleFromIntent() }`. `toggleFromIntent()` = `await ensureSetUp(); await pipeline?.toggleFromIntent()`. `SottoApp.swift`: `@State private var model = AppModel()`, `WindowGroup { ContentView(model: model) }`. `ContentView.swift`: takes `let model: AppModel`, renders from `model.pipeline`/`model.setupError`/`model.recoveryNotice`, `.task { await model.ensureSetUp() }`, delete the `.onReceive` bridge and all moved state.

- [ ] **Step 4: Tests.** `SottoTests/AppModelTests.swift`:

```swift
import Testing
@testable import Sotto

@MainActor
struct AppModelTests {
    @Test func intentHandlerIsRegisteredAtConstruction() async throws {
        let model = AppModel()
        _ = model
        #expect(IntentHandlers.shared.toggle != nil)   // cold background launch can toggle
    }
}
```

`InterruptionTests` additions:

```swift
    @Test func pauseByUserParksWithoutFallbackNotification() async throws {
        let source = FakeAudioSource()
        let notifications = FakeNotificationScheduler()
        let activity = FakeLiveActivityController()
        let pipeline = ListeningPipeline(
            source: source, recorder: FakeRecorder(),
            liveActivity: activity, notifications: notifications)

        await pipeline.start()
        await pipeline.pauseByUser()

        #expect(pipeline.status == .interrupted)
        #expect(pipeline.haltReason == .userPause)
        #expect(await notifications.scheduled == 0)          // user chose this; no "resume" nag
        #expect(activity.updates.last?.label == "Paused by you")
        #expect(activity.endedCount == 0)                    // activity survives — Resume works

        await pipeline.resumeFromInterruption()
        #expect(pipeline.status == .listening)
        #expect(pipeline.haltReason == nil)
    }

    @Test func systemInterruptionStillSchedulesNotification() async throws {
        let source = FakeAudioSource()
        let notifications = FakeNotificationScheduler()
        let pipeline = ListeningPipeline(
            source: source, recorder: FakeRecorder(),
            liveActivity: nil, notifications: notifications)
        await pipeline.start()
        await pipeline.interrupt()
        #expect(pipeline.haltReason == .systemInterruption)
        #expect(await notifications.scheduled == 1)
    }
```

- [ ] **Step 5: `xcodegen generate`, full suite green (existing InterruptionTests must pass unchanged apart from none — they don't touch toggle semantics), commit:** `git add Sotto SottoTests && git commit -m "feat: scene-independent AppModel, awaited intent toggle, user-pause park state"`

---

### Task 3: TranscriptionService types + persisted TranscriptionQueue + markdown writer

**Files:**
- Create: `Sotto/Transcription/TranscriptionService.swift`, `Sotto/Transcription/TranscriptionQueue.swift`, `Sotto/Transcription/TranscriptMarkdownWriter.swift`
- Modify: `Sotto/Segments/CAFSegmentWriter.swift` — the Task 1 review flagged that the m4a's Data Protection attribute lost its owner in the finalize split: add to the END of `transcodeToM4A(caf:m4a:)` (single owner — queue and salvage both benefit): `try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: m4a.path)` with the SPEC comment ("must never become .complete"). Likewise `TranscriptMarkdownWriter.write` sets the same attribute on the .md after writing.
- Modify: `SottoTests/Fakes.swift` (FakeTranscriptionService)
- Test: `SottoTests/TranscriptionQueueTests.swift`, `SottoTests/MarkdownWriterTests.swift`

**Interfaces:**
- Produces:

```swift
enum TranscriptionBackend: String, Codable, Sendable { case speechAnalyzer, deepgram }

struct TranscriptionSegment: Codable, Sendable, Equatable {
    let speaker: String?          // nil for on-device backends
    let text: String
    let startTime: TimeInterval
    let endTime: TimeInterval
}

struct TranscriptionResult: Codable, Sendable, Equatable {
    let text: String
    let segments: [TranscriptionSegment]
    let duration: TimeInterval
    let backend: TranscriptionBackend
}

enum TranscriptionError: Error { case unavailable, missingAPIKey, badResponse(Int), emptyAudio }

protocol TranscriptionService: Sendable {
    var backend: TranscriptionBackend { get }
    func transcribe(file: URL) async throws -> TranscriptionResult
}

struct TranscriptionJob: Codable, Sendable, Equatable, Identifiable {
    enum State: String, Codable, Sendable { case pending, done, failed }
    let id: UUID
    var cafURL: URL?              // nil once transcoded (or salvaged externally)
    let m4aURL: URL
    let startDate: Date
    let duration: TimeInterval
    let speechDuration: TimeInterval
    var attempts: Int
    var state: State
}

actor TranscriptionQueue {
    init(storeURL: URL? = nil,   // default: Application Support/transcription-jobs.json
         service: any TranscriptionService,
         maxAttempts: Int = 3)
    func enqueue(_ segment: FinalizedSegment)   // persists, then kicks drain
    func drain() async                          // serial; idempotent; safe to re-enter
    var jobs: [TranscriptionJob] { get }
    var pendingCount: Int { get }
}

enum TranscriptMarkdownWriter {
    /// Renders the SPEC markdown (frontmatter + body; speaker turns for deepgram) and
    /// writes it atomically next to the m4a (same basename, .md).
    static func write(result: TranscriptionResult, job: TranscriptionJob) throws -> URL
}
```

Worker step per job (document in code): (1) if `cafURL` set and the file exists → `CAFSegmentWriter.transcodeToM4A`, delete CAF, set `cafURL = nil`, persist. If `cafURL` set but MISSING and the m4a exists → salvage already transcoded it: set `cafURL = nil`, persist, continue. If both missing → mark `.failed`. (2) `service.transcribe(file: m4aURL)` → `TranscriptMarkdownWriter.write` → `.done`, persist. On throw: `attempts += 1`; `attempts >= maxAttempts` → `.failed`; persist either way and continue to the next job (never crash the drain).

- [ ] **Step 1: Failing tests.** `MarkdownWriterTests.swift`:

```swift
import Foundation
import Testing
@testable import Sotto

struct MarkdownWriterTests {
    private func job(in dir: URL) -> TranscriptionJob {
        TranscriptionJob(
            id: UUID(), cafURL: nil, m4aURL: dir.appendingPathComponent("09-15-30.m4a"),
            startDate: Date(timeIntervalSince1970: 1_773_000_000),
            duration: 342, speechDuration: 282, attempts: 0, state: .pending)
    }

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MDTests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func onDeviceMarkdownHasFrontmatterAndPlainBody() throws {
        let dir = tempDir()
        let result = TranscriptionResult(
            text: "Hello there. General conversation.",
            segments: [], duration: 342, backend: .speechAnalyzer)
        let url = try TranscriptMarkdownWriter.write(result: result, job: job(in: dir))

        #expect(url.lastPathComponent == "09-15-30.md")
        let md = try String(contentsOf: url, encoding: .utf8)
        #expect(md.hasPrefix("---\n"))
        #expect(md.contains("backend: speechAnalyzer"))
        #expect(md.contains("duration: 342"))
        #expect(md.contains("speechEnd: "))                  // startDate + speechDuration
        #expect(md.contains("# Conversation — "))
        #expect(md.contains("Hello there. General conversation."))
        #expect(!md.contains("**Speaker"))
    }

    @Test func deepgramMarkdownRendersSpeakerTurns() throws {
        let dir = tempDir()
        let result = TranscriptionResult(
            text: "Hi. Hey.",
            segments: [
                TranscriptionSegment(speaker: "1", text: "Hi.", startTime: 0, endTime: 1),
                TranscriptionSegment(speaker: "2", text: "Hey.", startTime: 1, endTime: 2),
            ],
            duration: 342, backend: .deepgram)
        let url = try TranscriptMarkdownWriter.write(result: result, job: job(in: dir))
        let md = try String(contentsOf: url, encoding: .utf8)
        #expect(md.contains("backend: deepgram"))
        #expect(md.contains("speakers: 2"))
        #expect(md.contains("**Speaker 1:** Hi."))
        #expect(md.contains("**Speaker 2:** Hey."))
    }
}
```

`TranscriptionQueueTests.swift`:

```swift
import AVFoundation
import Foundation
import Testing
@testable import Sotto

struct TranscriptionQueueTests {
    private func makeSegment(in dir: URL, speech: Bool = true) throws -> FinalizedSegment {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let caf = dir.appendingPathComponent("seg.caf")
        let m4a = dir.appendingPathComponent("seg.m4a")
        let writer = try CAFSegmentWriter(cafURL: caf, m4aURL: m4a)
        let samples = (0..<VADConstants.sampleRate).map {
            sinf(2 * .pi * 300 * Float($0) / Float(VADConstants.sampleRate)) * 0.4
        }
        try writer.append(samples)
        writer.close()
        return FinalizedSegment(
            cafURL: caf, m4aURL: m4a, startDate: Date(), duration: 1.0, speechDuration: 1.0)
    }

    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("QueueTests-\(UUID().uuidString)")
    }

    @Test func drainTranscodesTranscribesWritesMarkdownAndDeletesCAF() async throws {
        let dir = tempDir()
        let segment = try makeSegment(in: dir)
        let service = FakeTranscriptionService(text: "hello world")
        let queue = TranscriptionQueue(
            storeURL: dir.appendingPathComponent("jobs.json"), service: service)

        await queue.enqueue(segment)
        await queue.drain()

        #expect(!FileManager.default.fileExists(atPath: segment.cafURL.path))
        #expect(FileManager.default.fileExists(atPath: segment.m4aURL.path))
        let md = dir.appendingPathComponent("seg.md")
        #expect(try String(contentsOf: md, encoding: .utf8).contains("hello world"))
        #expect(await queue.jobs.first?.state == .done)
        #expect(await service.calls == 1)
    }

    @Test func jobsPersistAcrossQueueInstances() async throws {
        let dir = tempDir()
        let segment = try makeSegment(in: dir)
        let store = dir.appendingPathComponent("jobs.json")
        let failing = FakeTranscriptionService(text: "x", failuresBeforeSuccess: .max)
        let first = TranscriptionQueue(storeURL: store, service: failing, maxAttempts: 1)
        await first.enqueue(segment)
        await first.drain()
        #expect(await first.jobs.first?.state == .failed)

        // A fresh instance (new launch) reloads the same jobs file:
        let second = TranscriptionQueue(storeURL: store, service: FakeTranscriptionService(text: "y"))
        #expect(await second.jobs.count == 1)
        #expect(await second.jobs.first?.state == .failed)
    }

    @Test func retriesThenSucceeds() async throws {
        let dir = tempDir()
        let segment = try makeSegment(in: dir)
        let service = FakeTranscriptionService(text: "eventually", failuresBeforeSuccess: 2)
        let queue = TranscriptionQueue(
            storeURL: dir.appendingPathComponent("jobs.json"), service: service, maxAttempts: 5)
        await queue.enqueue(segment)
        await queue.drain()   // attempt 1 fails (still pending, attempts=1)
        await queue.drain()   // attempt 2 fails
        await queue.drain()   // attempt 3 succeeds
        #expect(await queue.jobs.first?.state == .done)
    }

    @Test func salvagedCAFIsToleratedWhenM4AAlreadyExists() async throws {
        let dir = tempDir()
        let segment = try makeSegment(in: dir)
        // Simulate the launch salvage sweep having already transcoded + deleted the CAF:
        try CAFSegmentWriter.transcodeToM4A(caf: segment.cafURL, m4a: segment.m4aURL)
        try FileManager.default.removeItem(at: segment.cafURL)

        let queue = TranscriptionQueue(
            storeURL: dir.appendingPathComponent("jobs.json"),
            service: FakeTranscriptionService(text: "salvaged"))
        await queue.enqueue(segment)
        await queue.drain()
        #expect(await queue.jobs.first?.state == .done)
    }

    @Test func bothFilesMissingMarksFailedWithoutThrowing() async throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ghost = FinalizedSegment(
            cafURL: dir.appendingPathComponent("ghost.caf"),
            m4aURL: dir.appendingPathComponent("ghost.m4a"),
            startDate: Date(), duration: 1, speechDuration: 1)
        let queue = TranscriptionQueue(
            storeURL: dir.appendingPathComponent("jobs.json"),
            service: FakeTranscriptionService(text: "x"))
        await queue.enqueue(ghost)
        await queue.drain()
        #expect(await queue.jobs.first?.state == .failed)
    }
}
```

`FakeTranscriptionService` in Fakes.swift:

```swift
actor FakeTranscriptionService: TranscriptionService {
    nonisolated let backend = TranscriptionBackend.speechAnalyzer
    private(set) var calls = 0
    private var remainingFailures: Int
    private let text: String

    init(text: String, failuresBeforeSuccess: Int = 0) {
        self.text = text
        self.remainingFailures = failuresBeforeSuccess
    }

    func transcribe(file: URL) async throws -> TranscriptionResult {
        calls += 1
        if remainingFailures > 0 {
            remainingFailures -= 1
            throw TranscriptionError.badResponse(500)
        }
        return TranscriptionResult(text: text, segments: [], duration: 1, backend: backend)
    }
}
```

- [ ] **Step 2: `xcodegen generate`, RED** (`cannot find 'TranscriptionQueue'`).

- [ ] **Step 3: Implement.** `TranscriptionService.swift` = the types verbatim from Interfaces. `TranscriptMarkdownWriter.swift`:

```swift
import Foundation

enum TranscriptMarkdownWriter {
    static func write(result: TranscriptionResult, job: TranscriptionJob) throws -> URL {
        let url = job.m4aURL.deletingPathExtension().appendingPathExtension("md")
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]   // local offset included below
        iso.timeZone = .current
        let timeFormatter = DateFormatter()
        timeFormatter.locale = Locale(identifier: "en_US_POSIX")
        timeFormatter.dateFormat = "h:mm a"

        var lines: [String] = ["---"]
        lines.append("date: \(iso.string(from: job.startDate))")
        lines.append("duration: \(Int(job.duration.rounded()))")
        lines.append("speechEnd: \(iso.string(from: job.startDate.addingTimeInterval(job.speechDuration)))")
        lines.append("backend: \(result.backend.rawValue)")
        let speakers = Set(result.segments.compactMap(\.speaker))
        if result.backend == .deepgram {
            lines.append("speakers: \(max(speakers.count, 1))")
        }
        lines.append("---")
        lines.append("")
        lines.append("# Conversation — \(timeFormatter.string(from: job.startDate))")
        lines.append("")
        if result.backend == .deepgram, !result.segments.isEmpty {
            for segment in result.segments {
                let speaker = segment.speaker.map { "**Speaker \($0):** " } ?? ""
                lines.append(speaker + segment.text)
                lines.append("")
            }
        } else {
            lines.append(result.text)
            lines.append("")
        }
        try lines.joined(separator: "\n")
            .write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
```

NOTE: ISO8601DateFormatter always renders UTC ("Z") — the SPEC requires the LOCAL UTC offset (e.g. `-04:00`). Use `Date.ISO8601FormatStyle` instead if simpler: `job.startDate.formatted(.iso8601(timeZone: .current))`… verify the chosen API actually emits the local offset (write the test expectation loosely: `md.contains("date: ")` plus a regex for `[+-]\d{2}:\d{2}$` on that line is acceptable to add); record what you used. `TranscriptionQueue.swift`:

```swift
import Foundation

/// SPEC "Transcription layer": persisted queue, never inline. Serial worker; drains
/// whenever the app runs; leftovers drain on next launch/foreground. Also the new home of
/// the CAF→m4a transcode (M3 review Critical #1 — moved OFF the interruption window).
actor TranscriptionQueue {
    private let storeURL: URL
    private let service: any TranscriptionService
    private let maxAttempts: Int
    private(set) var jobs: [TranscriptionJob] = []
    private var draining = false

    var pendingCount: Int { jobs.filter { $0.state == .pending }.count }

    init(storeURL: URL? = nil, service: any TranscriptionService, maxAttempts: Int = 3) {
        if let storeURL {
            self.storeURL = storeURL
        } else {
            let support = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask)[0]
            try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            self.storeURL = support.appendingPathComponent("transcription-jobs.json")
        }
        self.service = service
        self.maxAttempts = maxAttempts
        if let data = try? Data(contentsOf: self.storeURL),
           let loaded = try? JSONDecoder().decode([TranscriptionJob].self, from: data) {
            jobs = loaded
        }
    }

    func enqueue(_ segment: FinalizedSegment) {
        jobs.append(TranscriptionJob(
            id: UUID(), cafURL: segment.cafURL, m4aURL: segment.m4aURL,
            startDate: segment.startDate, duration: segment.duration,
            speechDuration: segment.speechDuration, attempts: 0, state: .pending))
        persist()
    }

    func drain() async {
        guard !draining else { return }   // serial: one worker at a time
        draining = true
        defer { draining = false }

        for index in jobs.indices where jobs[index].state == .pending {
            await step(index)
        }
    }

    private func step(_ index: Int) async {
        // Phase 1: ensure the m4a exists (deferred transcode; self-heals with salvage).
        if let caf = jobs[index].cafURL {
            let cafExists = FileManager.default.fileExists(atPath: caf.path)
            let m4aExists = FileManager.default.fileExists(atPath: jobs[index].m4aURL.path)
            if cafExists {
                do {
                    try CAFSegmentWriter.transcodeToM4A(caf: caf, m4a: jobs[index].m4aURL)
                    try? FileManager.default.removeItem(at: caf)
                    jobs[index].cafURL = nil
                } catch {
                    fail(index)
                    return
                }
            } else if m4aExists {
                jobs[index].cafURL = nil   // launch salvage got here first — fine
            } else {
                jobs[index].state = .failed
                persist()
                return
            }
            persist()
        }

        // Phase 2: transcribe + write the transcript.
        do {
            let result = try await service.transcribe(file: jobs[index].m4aURL)
            _ = try TranscriptMarkdownWriter.write(result: result, job: jobs[index])
            jobs[index].state = .done
        } catch {
            fail(index)
        }
        persist()
    }

    private func fail(_ index: Int) {
        jobs[index].attempts += 1
        if jobs[index].attempts >= maxAttempts {
            jobs[index].state = .failed
        }
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(jobs) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }
}
```

TRACE NOTE for the retry test: a transcode failure calls `fail()` (attempts++), and a transcribe failure likewise — with `maxAttempts: 5` and `failuresBeforeSuccess: 2`, drains 1 and 2 leave state `.pending`, drain 3 succeeds. Verify `fail()` leaves `.pending` when attempts < maxAttempts (it does — state only set on the threshold).

- [ ] **Step 4: GREEN (7 new tests), commit:** `git add Sotto/Transcription SottoTests && git commit -m "feat: persisted transcription queue with deferred transcode and markdown transcripts"`

---

### Task 4: SpeechAnalyzerService (on-device, default)

**Files:**
- Create: `Sotto/Transcription/SpeechAnalyzerService.swift`
- Test: `SottoTests/SpeechAnalyzerServiceTests.swift`

**Interfaces:**
- Produces: `struct SpeechAnalyzerService: TranscriptionService { let backend = TranscriptionBackend.speechAnalyzer; init(locale: Locale = .current); func transcribe(file: URL) async throws -> TranscriptionResult }` plus `static func assetsInstalled(for locale: Locale) async -> Bool` (Task 6 uses it for the drain gate; the download UI is M6).

- [ ] **Step 1: Implement `Sotto/Transcription/SpeechAnalyzerService.swift`**

```swift
import AVFoundation
import Foundation
import Speech

/// On-device transcription via SpeechAnalyzer/SpeechTranscriber (iOS 26). No permission
/// prompt exists for this API — SPEC: never add NSSpeechRecognitionUsageDescription.
/// Custom preset per SPEC: `.transcription` + `.audioTimeRange` for time-coded segments.
struct SpeechAnalyzerService: TranscriptionService {
    let backend = TranscriptionBackend.speechAnalyzer
    let locale: Locale

    init(locale: Locale = .current) {
        self.locale = locale
    }

    static func assetsInstalled(for locale: Locale) async -> Bool {
        guard SpeechTranscriber.isAvailable else { return false }
        let installed = await SpeechTranscriber.installedLocales
        return installed.contains { $0.identifier(.bcp47) == locale.identifier(.bcp47) }
    }

    func transcribe(file: URL) async throws -> TranscriptionResult {
        guard SpeechTranscriber.isAvailable else { throw TranscriptionError.unavailable }
        guard await Self.assetsInstalled(for: locale) else { throw TranscriptionError.unavailable }

        let base = SpeechTranscriber.Preset.transcription
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: base.transcriptionOptions,
            reportingOptions: base.reportingOptions,
            attributeOptions: base.attributeOptions.union([.audioTimeRange]))
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        let audioFile = try AVAudioFile(forReading: file)
        let duration = Double(audioFile.length) / audioFile.processingFormat.sampleRate

        // Collect results concurrently with analysis; the sequence finishes after
        // finalizeAndFinishThroughEndOfInput().
        async let collected: [TranscriptionSegment] = {
            var segments: [TranscriptionSegment] = []
            for try await result in transcriber.results {
                let text = String(result.text.characters)
                guard !text.isEmpty else { continue }
                // Adapt-allowed zone: pull start/end from the audioTimeRange attribute runs
                // if exposed; otherwise fall back to CMTime properties on the result.
                var start: TimeInterval = 0
                var end: TimeInterval = duration
                if let range = result.range {
                    start = range.start.seconds
                    end = range.end.seconds
                }
                segments.append(TranscriptionSegment(
                    speaker: nil, text: text, startTime: start, endTime: end))
            }
            return segments
        }()

        _ = try await analyzer.analyzeSequence(from: audioFile)
        try await analyzer.finalizeAndFinishThroughEndOfInput()

        let segments = try await collected
        let text = segments.map(\.text).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return TranscriptionResult(
            text: text, segments: segments, duration: duration, backend: backend)
    }
}
```

ADAPT-ALLOWED: `result.range` may not exist under that name — inspect `SpeechTranscriber.Result`'s members in the swiftinterface (`grep -n "struct Result" -A 12` on the Speech swiftinterface) and use whatever exposes the result's audio time range (the SDK shows `resultsFinalizationTime: CMTime` and more); if only the AttributedString run attribute carries it, iterate `result.text.runs` with the `audioTimeRange` attribute key. Keep the `TranscriptionSegment` contract; record exactly what the SDK offered.

- [ ] **Step 2: Tests — `SottoTests/SpeechAnalyzerServiceTests.swift`** (must not download assets):

```swift
import AVFoundation
import Foundation
import Testing
@testable import Sotto

struct SpeechAnalyzerServiceTests {
    @Test func throwsUnavailableRatherThanPromptingWhenAssetsMissing() async throws {
        // On simulators without Apple Intelligence assets this exercises the guard path;
        // on machines WITH assets installed it exercises real transcription instead.
        let service = SpeechAnalyzerService(locale: Locale(identifier: "en_US"))
        guard await SpeechAnalyzerService.assetsInstalled(for: Locale(identifier: "en_US")) else {
            await #expect(throws: TranscriptionError.self) {
                _ = try await service.transcribe(
                    file: URL(fileURLWithPath: "/nonexistent.m4a"))
            }
            return
        }
        // Assets installed: transcribe 1 s of synthetic tone — must complete without
        // throwing and produce a (possibly empty) result. Real-speech accuracy is a
        // device/manual concern, not a unit gate.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SATests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let caf = dir.appendingPathComponent("t.caf"); let m4a = dir.appendingPathComponent("t.m4a")
        let writer = try CAFSegmentWriter(cafURL: caf, m4aURL: m4a)
        try writer.append((0..<VADConstants.sampleRate).map {
            sinf(2 * .pi * 300 * Float($0) / Float(VADConstants.sampleRate)) * 0.3
        })
        writer.close()
        try CAFSegmentWriter.transcodeToM4A(caf: caf, m4a: m4a)
        let result = try await service.transcribe(file: m4a)
        #expect(result.backend == .speechAnalyzer)
        #expect(result.duration > 0.5)
    }
}
```

- [ ] **Step 3: `xcodegen generate`, suite green, commit:** `git add Sotto/Transcription/SpeechAnalyzerService.swift SottoTests/SpeechAnalyzerServiceTests.swift && git commit -m "feat: on-device SpeechAnalyzerService with availability and asset gates"`
Report which branch the test took on this simulator (assets installed or not) — that answers spec open question 4 for the sim environment.

---

### Task 5: DeepgramService + KeychainStore

**Files:**
- Create: `Sotto/Transcription/DeepgramService.swift`, `Sotto/Transcription/KeychainStore.swift`
- Test: `SottoTests/DeepgramServiceTests.swift`

**Interfaces:**
- Produces: `struct KeychainStore: Sendable { init(service: String = "com.decanlys.Sotto"); func set(_ value: String, for key: String) -> Bool; func get(_ key: String) -> String?; func delete(_ key: String) }` and `struct DeepgramService: TranscriptionService { let backend = .deepgram; init(apiKeyProvider: @escaping @Sendable () -> String?, session: URLSession = .shared) }`.

- [ ] **Step 1: Failing tests — `SottoTests/DeepgramServiceTests.swift`** (URLProtocol mock; no network):

```swift
import Foundation
import Testing
@testable import Sotto

final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, data) = Self.handler!(request)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

struct DeepgramServiceTests {
    private func mockedSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func audioFixture() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DGTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("a.m4a")
        try Data([0x00, 0x01, 0x02]).write(to: url)
        return url
    }

    @Test func buildsSpecCompliantRequestAndParsesUtterances() async throws {
        let requestBox = Mutex<URLRequest?>(nil)
        MockURLProtocol.handler = { request in
            requestBox.withLock { $0 = request }
            let body = """
            {"results": {"channels": [{"alternatives": [{"transcript": "hi there"}]}],
             "utterances": [
               {"start": 0.5, "end": 1.2, "transcript": "hi", "speaker": 0},
               {"start": 1.4, "end": 2.0, "transcript": "there", "speaker": 1}
             ]}}
            """
            return (200, Data(body.utf8))
        }
        let service = DeepgramService(apiKeyProvider: { "test-key" }, session: mockedSession())
        let result = try await service.transcribe(file: try audioFixture())

        let request = requestBox.withLock { $0 }!
        let url = request.url!.absoluteString
        #expect(url.hasPrefix("https://api.deepgram.com/v1/listen?"))
        #expect(url.contains("model=nova-3"))
        #expect(url.contains("diarize_model=latest"))
        #expect(!url.contains("diarize=true"))               // deprecated param must be absent
        #expect(url.contains("utterances=true"))
        #expect(url.contains("smart_format=true"))
        #expect(url.contains("mip_opt_out=true"))            // privacy: training opt-out always
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Token test-key")

        #expect(result.backend == .deepgram)
        #expect(result.text == "hi there")
        #expect(result.segments.count == 2)
        #expect(result.segments[0].speaker == "1")           // speaker index 0 → "Speaker 1"
        #expect(result.segments[1].speaker == "2")
        #expect(abs(result.segments[0].startTime - 0.5) < 0.001)
    }

    @Test func missingKeyThrowsBeforeAnyNetworkCall() async throws {
        MockURLProtocol.handler = { _ in (500, Data()) }
        let service = DeepgramService(apiKeyProvider: { nil }, session: mockedSession())
        await #expect(throws: TranscriptionError.self) {
            _ = try await service.transcribe(file: try audioFixture())
        }
    }

    @Test func non200ThrowsBadResponse() async throws {
        MockURLProtocol.handler = { _ in (401, Data("{}".utf8)) }
        let service = DeepgramService(apiKeyProvider: { "k" }, session: mockedSession())
        await #expect(throws: TranscriptionError.self) {
            _ = try await service.transcribe(file: try audioFixture())
        }
    }

    @Test func keychainRoundTrip() {
        let store = KeychainStore(service: "com.decanlys.Sotto.tests")
        store.delete("dg")
        #expect(store.get("dg") == nil)
        #expect(store.set("secret-123", for: "dg"))
        #expect(store.get("dg") == "secret-123")
        #expect(store.set("secret-456", for: "dg"))           // overwrite
        #expect(store.get("dg") == "secret-456")
        store.delete("dg")
        #expect(store.get("dg") == nil)
    }
}
```

Add `import Synchronization` for `Mutex`.

- [ ] **Step 2: `xcodegen generate`, RED.**

- [ ] **Step 3: Implement.** `KeychainStore.swift`:

```swift
import Foundation
import Security

/// Minimal generic-password wrapper — SPEC: the Deepgram key lives in the Keychain, never
/// UserDefaults. kSecAttrAccessibleAfterFirstUnlock matches the app's locked-phone writes.
struct KeychainStore: Sendable {
    let service: String

    init(service: String = "com.decanlys.Sotto") {
        self.service = service
    }

    private func baseQuery(for key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: key]
    }

    @discardableResult
    func set(_ value: String, for key: String) -> Bool {
        delete(key)
        var query = baseQuery(for: key)
        query[kSecValueData as String] = Data(value.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    func get(_ key: String) -> String? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func delete(_ key: String) {
        SecItemDelete(baseQuery(for: key) as CFDictionary)
    }
}
```

`DeepgramService.swift`:

```swift
import Foundation

/// Cloud transcription, BYOK (SPEC "DeepgramService"). Params per spec: nova-3,
/// diarize_model=latest (NEVER the deprecated diarize=true), utterances, smart_format,
/// and mip_opt_out=true always — the training opt-out is part of the privacy story.
struct DeepgramService: TranscriptionService {
    let backend = TranscriptionBackend.deepgram
    let apiKeyProvider: @Sendable () -> String?
    let session: URLSession

    init(apiKeyProvider: @escaping @Sendable () -> String?, session: URLSession = .shared) {
        self.apiKeyProvider = apiKeyProvider
        self.session = session
    }

    func transcribe(file: URL) async throws -> TranscriptionResult {
        guard let key = apiKeyProvider() else { throw TranscriptionError.missingAPIKey }
        let audio = try Data(contentsOf: file)
        guard !audio.isEmpty else { throw TranscriptionError.emptyAudio }

        var components = URLComponents(string: "https://api.deepgram.com/v1/listen")!
        components.queryItems = [
            URLQueryItem(name: "model", value: "nova-3"),
            URLQueryItem(name: "diarize_model", value: "latest"),
            URLQueryItem(name: "utterances", value: "true"),
            URLQueryItem(name: "smart_format", value: "true"),
            URLQueryItem(name: "mip_opt_out", value: "true"),
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("Token \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("audio/mp4", forHTTPHeaderField: "Content-Type")
        request.httpBody = audio

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw TranscriptionError.badResponse((response as? HTTPURLResponse)?.statusCode ?? -1)
        }

        let decoded = try JSONDecoder().decode(DeepgramResponse.self, from: data)
        let segments = (decoded.results.utterances ?? []).map { utterance in
            TranscriptionSegment(
                speaker: utterance.speaker.map { String($0 + 1) },   // 0-based → "Speaker 1"
                text: utterance.transcript,
                startTime: utterance.start,
                endTime: utterance.end)
        }
        let text = decoded.results.channels.first?.alternatives.first?.transcript
            ?? segments.map(\.text).joined(separator: " ")
        let duration = segments.last?.endTime ?? 0
        return TranscriptionResult(
            text: text, segments: segments, duration: duration, backend: backend)
    }
}

private struct DeepgramResponse: Decodable {
    struct Results: Decodable {
        struct Channel: Decodable {
            struct Alternative: Decodable { let transcript: String }
            let alternatives: [Alternative]
        }
        struct Utterance: Decodable {
            let start: TimeInterval
            let end: TimeInterval
            let transcript: String
            let speaker: Int?
        }
        let channels: [Channel]
        let utterances: [Utterance]?
    }
    let results: Results
}
```

- [ ] **Step 4: GREEN (4 new tests), commit:** `git add Sotto/Transcription SottoTests/DeepgramServiceTests.swift && git commit -m "feat: Deepgram BYOK service with keychain storage and spec params"`

---

### Task 6: Wire the queue into AppModel + integration + e2e

**Files:**
- Modify: `Sotto/App/AppModel.swift`
- Modify: `SottoTests/RecorderIntegrationTests.swift`
- Test: run everything; simulator e2e

**Interfaces:**
- Consumes: everything. AppModel gains `private(set) var queue: TranscriptionQueue?`.

- [ ] **Step 1: Wiring in `AppModel.ensureSetUp()`** (after the recorder is constructed, before the pipeline):

```swift
            // Backend selection: on-device by default; Deepgram only when a key exists AND
            // assets make sense to skip (full Settings toggle is M6).
            let keychain = KeychainStore()
            let service: any TranscriptionService
            if let _ = keychain.get("deepgramAPIKey") {
                service = DeepgramService(apiKeyProvider: { KeychainStore().get("deepgramAPIKey") })
            } else {
                service = SpeechAnalyzerService()
            }
            let transcriptionQueue = TranscriptionQueue(service: service)
            self.queue = transcriptionQueue
            await recorder.setSegmentHandler { segment in
                Task {
                    await transcriptionQueue.enqueue(segment)
                    await transcriptionQueue.drain()
                }
            }
```

and at the END of `ensureSetUp()` (after observer wiring): `Task { await transcriptionQueue.drain() }` — leftovers from the previous run drain at launch (SPEC). Also in the resume path is unnecessary (drain is kicked per enqueue). NOTE: if `SpeechAnalyzerService.assetsInstalled` is false at drain time the service throws `.unavailable` per job and jobs burn attempts — acceptable for M4 (M6 adds the download UI + drain gating); cap the damage by checking once in `ensureSetUp`: if on-device assets are missing AND no Deepgram key, log a `recoveryNotice`-style line into the pipeline eventLog? Keep it simple: set `recoveryNotice = "Transcription model not installed — recordings will be kept and transcribed once it is available."` and DON'T kick the launch drain in that case (jobs stay pending). Implement exactly that:

```swift
            let onDeviceReady = await SpeechAnalyzerService.assetsInstalled(for: .current)
            let hasDeepgramKey = keychain.get("deepgramAPIKey") != nil
            ...
            if onDeviceReady || hasDeepgramKey {
                Task { await transcriptionQueue.drain() }
            } else {
                recoveryNotice = "Transcription model not installed — recordings are kept and will be transcribed later."
            }
```

(Compose with the existing crash-recovery notice: append with "\n" if already set.)

- [ ] **Step 2: Integration test update — `RecorderIntegrationTests`:** extend the existing whole-stack test: construct a `TranscriptionQueue` with `FakeTranscriptionService(text: "integration transcript")` and the machine's segment handler enqueues+drains into it (mirroring AppModel's wiring); assert at the end: `.md` exists next to the m4a and contains "integration transcript"; CAF deleted by the queue; job state done.

- [ ] **Step 3: Full suite green, commit:** `git add Sotto SottoTests && git commit -m "feat: wire transcription queue into app model with backend selection"`

- [ ] **Step 4: e2e:** rebuild, reinstall, relaunch on the iPhone Air simulator; screenshot; check logs for crashes. Report whether on-device speech assets are installed on this simulator (from Task 4's report) — if they are, a real spoken test by the human should now produce a transcript file.

## Self-review notes

- Spec M4 coverage: persisted queue never-inline ✓ (T3); drain on launch/foreground ✓ (T6; foreground == every app run — scenePhase-triggered drain deferred to M6 with the settings UI); SpeechAnalyzer custom preset + audioTimeRange ✓ (T4); asset check + explicit offline-at-first-run handling ✓ (T4 guard + T6 notice; download UI is M6 per spec's first-launch flow); no speech permission ✓; device gate ✓ (isAvailable → unavailable error; hard unsupported-device screen is M6); Deepgram params/BYOK/Keychain ✓ (T5); Wi-Fi-only toggle + retry backoff + fall-back-to-on-device-after-N-failures: queue retries ✓, but Wi-Fi-only and backend fallback are Settings-coupled — deferred to M6 with a note (SPEC lists them under operational rules; the queue's `maxAttempts`+`failed` state is the M4 substrate). Deliberate: `.md` placeholder-at-finalize (spec pipeline diagram) is subsumed by queue-writes-md-when-done; `_day.json` is M5.
- M3 Criticals: #1 closed by T1+T3 (close() fast; transcode in worker; interruption window now does close-only). #2 closed by T2 (AppModel in App scope + awaited intent). Important #4 closed by T2 (pauseByUser + label). eventLog cap ✓ T2.
- Type consistency: `FinalizedSegment(cafURL:m4aURL:startDate:duration:speechDuration:)` used identically in T1/T3/T6; `TranscriptionJob` fields match writer usage; `FakeTranscriptionService(text:failuresBeforeSuccess:)` matches all test call sites; `IntentHandlers.shared.toggle` optional closure awaited with `?()`.
- Known risks flagged to implementers: ISO8601 local-offset rendering (T3 note); `SpeechTranscriber.Result` member names (T4 adapt zone); `installedLocales` possibly `get async` (both call sites already `await`).

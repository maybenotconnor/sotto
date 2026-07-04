# M2 — Recorder State Machine + Crash-Safe Writer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement spec milestone M2: the five-state recorder (Idle ▸ Listening ▸ Recording ▸ Silence ▸ Interrupted), a crash-safe segment writer (CAF during capture → AAC .m4a at finalize), segment guards (45 s silence timeout, min 3 s, max 2 h, 500 MB disk), and heartbeat/unclean-shutdown salvage — so a listening session ends with real `.m4a` conversation files on disk.

**Architecture:** A new `RecorderStateMachine` **actor** owns everything per-chunk: pre-roll buffer, VAD detector, segment writer, guards, and silence timing (measured in **sample counts**, not wall clocks — transitions are deterministic under test). The battle-tested `ListeningPipeline` stays as the @MainActor facade: it keeps its start/stop/queued-stop/deinit semantics and simply forwards each chunk to the recorder, publishing the returned snapshot. This also discharges the standing review carryover: pre-roll and disk work move **off the MainActor**. Capture writes 16 kHz mono **Int16 PCM CAF** (readable even if the process dies mid-file — CAF needs no finalization); finalize transcodes to AAC .m4a (~0.5 MB/min) and deletes the CAF. On launch, orphaned CAFs are salvaged by the same transcode path.

**Tech Stack:** Swift 6 strict concurrency, AVFoundation (`AVAudioFile` for both CAF write and AAC transcode), Swift Testing, XcodeGen, FluidAudio 0.15.4 (unchanged).

## Global Constraints

- Test command (every task): `xcodebuild test -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone Air' 2>&1 | tail -5` → `** TEST SUCCEEDED **`. Slow, not hung. If simulator reports Busy/preflight: `xcrun simctl shutdown all`, retry.
- **This plan adds new files** — run `xcodegen generate` after creating files, before building.
- Zero Swift warnings after every task (`grep "warning:" <log> | grep -v appintentsmetadataprocessor` → empty).
- Swift 6 language mode, `SWIFT_DEFAULT_ACTOR_ISOLATION: nonisolated` — isolation always explicit.
- Spec values (verbatim from docs/SPEC.md): silence timeout default **45 s** (range 15–120), min segment **3 s** (1–10), max segment **2 h** force-finalize-and-continue, disk guard **500 MB** free, pre-roll **1.0 s**, output **AAC .m4a, 16 kHz mono, ~64 kbps**, segment files named `HH-mm-ss` in a `Documents/Sotto/yyyy-MM-dd/` folder (LOCAL date the segment started).
- Existing contracts that must survive: `ListeningPipeline.stop()` returning implies idle+drained (queued stops suspend); `.starting` status truthfulness; deinit teardown; `AudioSource.stop()` contract; `VADConstants.chunkSize` as chunk-size source of truth; every existing test not explicitly rewritten by Task 5 keeps passing.
- Baseline: 34 tests passing. Do not predict exact totals — assert "all green" plus the new tests you added.
- `Date()` is allowed in app code (it is banned only in Workflow scripts, not Swift).
- Git commit messages end with:

  Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>

## File Structure

```
Sotto/Segments/SegmentWriting.swift      ← FinalizedSegment, SegmentWriting, SegmentWriterFactory
Sotto/Segments/CAFSegmentWriter.swift    ← CAF writer + transcode + concrete factory
Sotto/Segments/SegmentStore.swift        ← date folders, URL pairs, disk-free check, orphan scan
Sotto/Recorder/RecorderTypes.swift       ← RecorderState, RecorderSnapshot, RecorderConfig, SegmentRecording
Sotto/Recorder/RecorderStateMachine.swift← the actor
Sotto/Recorder/HeartbeatStore.swift      ← heartbeat JSON + OrphanSalvager
Sotto/Pipeline/ListeningPipeline.swift   ← slims to facade (modify)
Sotto/App/ContentView.swift              ← five-state UI + salvage/banner (modify)
SottoTests/SegmentWriterTests.swift, SegmentStoreTests.swift, RecorderStateMachineTests.swift,
HeartbeatTests.swift, RecorderIntegrationTests.swift (new); ListeningPipelineTests.swift, Fakes.swift (modify)
```

---

### Task 1: SegmentWriting types + CAFSegmentWriter

**Files:**
- Create: `Sotto/Segments/SegmentWriting.swift`
- Create: `Sotto/Segments/CAFSegmentWriter.swift`
- Test: `SottoTests/SegmentWriterTests.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces (Tasks 3–6 rely on these exactly):

```swift
struct FinalizedSegment: Sendable, Equatable {
    let audioURL: URL              // final .m4a
    let startDate: Date
    let duration: TimeInterval     // total audio written, incl. trailing silence
    let speechDuration: TimeInterval
}

protocol SegmentWriting {          // NOT Sendable: confined inside the recorder actor
    var writtenSampleCount: Int { get }
    func append(_ samples: [Float]) throws
    func finalize() throws -> URL  // transcode → m4a, delete CAF, return m4a URL
    func discard()                 // delete both files, no output
}

protocol SegmentWriterFactory: Sendable {
    func makeWriter(startDate: Date) throws -> any SegmentWriting
}

// CAFSegmentWriter also exposes, for the Task 4 salvager:
// static func transcodeToM4A(caf: URL, m4a: URL) throws
```

- [ ] **Step 1: Write the failing tests — `SottoTests/SegmentWriterTests.swift`**

```swift
import AVFoundation
import Foundation
import Testing
@testable import Sotto

struct SegmentWriterTests {
    private func tempURLs() -> (caf: URL, m4a: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SegmentWriterTests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (dir.appendingPathComponent("seg.caf"), dir.appendingPathComponent("seg.m4a"))
    }

    private func sineChunk(seconds: Double) -> [Float] {
        let count = Int(seconds * Double(VADConstants.sampleRate))
        return (0..<count).map { sinf(2 * .pi * 440 * Float($0) / Float(VADConstants.sampleRate)) * 0.5 }
    }

    @Test func writesCAFWhileAppendingWithoutFinalize() throws {
        let (caf, m4a) = tempURLs()
        let writer = try CAFSegmentWriter(cafURL: caf, m4aURL: m4a)
        try writer.append(sineChunk(seconds: 0.5))
        #expect(writer.writtenSampleCount == VADConstants.sampleRate / 2)
        #expect(FileManager.default.fileExists(atPath: caf.path))
        #expect(!FileManager.default.fileExists(atPath: m4a.path))
    }

    @Test func finalizeProducesReadableM4AAndDeletesCAF() throws {
        let (caf, m4a) = tempURLs()
        let writer = try CAFSegmentWriter(cafURL: caf, m4aURL: m4a)
        try writer.append(sineChunk(seconds: 1.0))
        let url = try writer.finalize()
        #expect(url == m4a)
        #expect(!FileManager.default.fileExists(atPath: caf.path))
        let file = try AVAudioFile(forReading: m4a)
        let duration = Double(file.length) / file.processingFormat.sampleRate
        #expect(abs(duration - 1.0) < 0.15)   // AAC priming/padding tolerance
    }

    @Test func discardRemovesEverything() throws {
        let (caf, m4a) = tempURLs()
        let writer = try CAFSegmentWriter(cafURL: caf, m4aURL: m4a)
        try writer.append(sineChunk(seconds: 0.3))
        writer.discard()
        #expect(!FileManager.default.fileExists(atPath: caf.path))
        #expect(!FileManager.default.fileExists(atPath: m4a.path))
    }

    @Test func unfinalizedCAFIsSalvageableByTranscode() throws {
        let (caf, m4a) = tempURLs()
        do {
            let writer = try CAFSegmentWriter(cafURL: caf, m4aURL: m4a)
            try writer.append(sineChunk(seconds: 0.8))
            // Simulate a crash: writer dropped without finalize() or discard().
        }
        try CAFSegmentWriter.transcodeToM4A(caf: caf, m4a: m4a)
        let file = try AVAudioFile(forReading: m4a)
        let duration = Double(file.length) / file.processingFormat.sampleRate
        #expect(abs(duration - 0.8) < 0.15)
    }
}
```

- [ ] **Step 2: `xcodegen generate`, then run tests to verify RED**

Expected: BUILD FAILURE — `cannot find 'CAFSegmentWriter' in scope`.

- [ ] **Step 3: Create `Sotto/Segments/SegmentWriting.swift`**

```swift
import Foundation

/// A finished conversation segment: the transcoded .m4a plus timing metadata.
/// M4's transcription queue consumes these; M5 derives `speechEnd` frontmatter
/// as `startDate + speechDuration`.
struct FinalizedSegment: Sendable, Equatable {
    let audioURL: URL
    let startDate: Date
    let duration: TimeInterval
    let speechDuration: TimeInterval
}

/// One open segment on disk. Deliberately NOT Sendable — instances are created and
/// used exclusively inside the RecorderStateMachine actor.
protocol SegmentWriting {
    var writtenSampleCount: Int { get }
    func append(_ samples: [Float]) throws
    /// Transcodes the capture file to .m4a, deletes the capture file, returns the .m4a URL.
    func finalize() throws -> URL
    /// Deletes everything; the segment never happened (min-length guard).
    func discard()
}

protocol SegmentWriterFactory: Sendable {
    func makeWriter(startDate: Date) throws -> any SegmentWriting
}
```

- [ ] **Step 4: Create `Sotto/Segments/CAFSegmentWriter.swift`**

```swift
import AVFoundation
import Foundation

/// Crash-safe segment writer (SPEC "Recording writer", option 2): capture is written as
/// 16 kHz mono Int16 PCM **CAF** — CAF is valid without finalization, so a process death
/// mid-segment loses nothing already flushed. `finalize()` transcodes to AAC .m4a
/// (~0.5 MB/min) and removes the CAF. The same transcode salvages orphaned CAFs on launch.
final class CAFSegmentWriter: SegmentWriting {
    enum WriterError: Error {
        case bufferAllocationFailed
    }

    private let cafURL: URL
    private let m4aURL: URL
    private var file: AVAudioFile?
    private(set) var writtenSampleCount = 0

    init(cafURL: URL, m4aURL: URL) throws {
        self.cafURL = cafURL
        self.m4aURL = m4aURL
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Double(VADConstants.sampleRate),
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        // Write via a Float32 processing format; AVAudioFile converts to Int16 on disk.
        self.file = try AVAudioFile(
            forWriting: cafURL, settings: settings,
            commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    func append(_ samples: [Float]) throws {
        guard let file, !samples.isEmpty else { return }
        // (empty append happens legitimately: segment rotation flushes an empty pre-roll;
        // AVAudioPCMBuffer with zero capacity would return nil and throw spuriously)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(samples.count))
        else {
            throw WriterError.bufferAllocationFailed
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { pointer in
            buffer.floatChannelData![0].update(from: pointer.baseAddress!, count: samples.count)
        }
        try file.write(from: buffer)
        writtenSampleCount += samples.count
    }

    func finalize() throws -> URL {
        file = nil   // AVAudioFile flushes and closes on release
        try Self.transcodeToM4A(caf: cafURL, m4a: m4aURL)
        try? FileManager.default.removeItem(at: cafURL)
        return m4aURL
    }

    func discard() {
        file = nil
        try? FileManager.default.removeItem(at: cafURL)
        try? FileManager.default.removeItem(at: m4aURL)
    }

    /// Also used by OrphanSalvager for CAFs left behind by an unclean shutdown.
    static func transcodeToM4A(caf: URL, m4a: URL) throws {
        let input = try AVAudioFile(forReading: caf)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: Double(VADConstants.sampleRate),
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 48_000,   // AAC-LC @16 kHz mono caps at 48 kbps ('!dat' above it)
        ]
        let output = try AVAudioFile(forWriting: m4a, settings: settings)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 32_768)
        else {
            throw WriterError.bufferAllocationFailed
        }
        while input.framePosition < input.length {
            try input.read(into: buffer)
            if buffer.frameLength == 0 { break }
            try output.write(from: buffer)
        }
    }
}

struct CAFSegmentWriterFactory: SegmentWriterFactory {
    let store: SegmentStore

    func makeWriter(startDate: Date) throws -> any SegmentWriting {
        let paths = try store.pathsForSegment(startingAt: startDate)
        return try CAFSegmentWriter(cafURL: paths.cafURL, m4aURL: paths.m4aURL)
    }
}
```

NOTE: `CAFSegmentWriterFactory` references `SegmentStore` from Task 2. If executing tasks strictly in order, comment the factory struct out in this task and let Task 2's commit add it — or (preferred) implement Tasks 1 and 2 against the same working tree and let each task's commit stage only its own files; the factory compiles once Task 2's `SegmentStore.swift` exists. If Task 1 must build standalone, move `CAFSegmentWriterFactory` into Task 2's file list instead — note which you did in your report.

- [ ] **Step 5: Run tests to verify GREEN** (if the factory blocked the build, apply the note above first)

Expected: `** TEST SUCCEEDED **`, all green including 4 new.

- [ ] **Step 6: Commit**

```bash
git add Sotto/Segments SottoTests/SegmentWriterTests.swift
git commit -m "feat: crash-safe CAF segment writer with m4a finalize"
```

---

### Task 2: SegmentStore

**Files:**
- Create: `Sotto/Segments/SegmentStore.swift`
- Test: `SottoTests/SegmentStoreTests.swift`
- (If Task 1 deferred `CAFSegmentWriterFactory`, it lands here.)

**Interfaces:**
- Consumes: nothing new.
- Produces:

```swift
struct SegmentPaths: Sendable, Equatable {
    let cafURL: URL
    let m4aURL: URL
}

struct SegmentStore: Sendable {
    let rootDirectory: URL                       // default: Documents/Sotto
    init(rootDirectory: URL? = nil)
    func pathsForSegment(startingAt date: Date) throws -> SegmentPaths
    func freeDiskBytes() -> Int64
    func orphanedCAFs() -> [URL]                 // recursive *.caf scan under root
}
```

- [ ] **Step 1: Write the failing tests — `SottoTests/SegmentStoreTests.swift`**

```swift
import Foundation
import Testing
@testable import Sotto

struct SegmentStoreTests {
    private func tempStore() -> SegmentStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SegmentStoreTests-\(UUID().uuidString)")
        return SegmentStore(rootDirectory: dir)
    }

    @Test func createsLocalDateFolderAndTimeNamedPair() throws {
        let store = tempStore()
        var components = DateComponents()
        components.year = 2026; components.month = 3; components.day = 14
        components.hour = 9; components.minute = 15; components.second = 30
        let date = Calendar.current.date(from: components)!

        let paths = try store.pathsForSegment(startingAt: date)

        #expect(paths.cafURL.lastPathComponent == "09-15-30.caf")
        #expect(paths.m4aURL.lastPathComponent == "09-15-30.m4a")
        #expect(paths.cafURL.deletingLastPathComponent().lastPathComponent == "2026-03-14")
        #expect(FileManager.default.fileExists(
            atPath: paths.cafURL.deletingLastPathComponent().path))   // folder created
    }

    @Test func collidingSecondGetsSuffixedName() throws {
        let store = tempStore()
        let date = Date()
        let first = try store.pathsForSegment(startingAt: date)
        FileManager.default.createFile(atPath: first.cafURL.path, contents: Data())
        let second = try store.pathsForSegment(startingAt: date)
        #expect(second.cafURL != first.cafURL)
        #expect(second.cafURL.lastPathComponent.hasSuffix("-2.caf"))
    }

    @Test func freeDiskBytesIsPositive() {
        let store = tempStore()
        #expect(store.freeDiskBytes() > 0)
    }

    @Test func findsOrphanedCAFsRecursively() throws {
        let store = tempStore()
        let paths = try store.pathsForSegment(startingAt: Date())
        FileManager.default.createFile(atPath: paths.cafURL.path, contents: Data([0x01]))
        let orphans = store.orphanedCAFs()
        #expect(orphans == [paths.cafURL])
    }
}
```

- [ ] **Step 2: `xcodegen generate`, run tests to verify RED**

Expected: BUILD FAILURE — `cannot find 'SegmentStore' in scope`.

- [ ] **Step 3: Create `Sotto/Segments/SegmentStore.swift`**

```swift
import Foundation

struct SegmentPaths: Sendable, Equatable {
    let cafURL: URL
    let m4aURL: URL
}

/// Segment file placement per SPEC "File output": `Documents/Sotto/<yyyy-MM-dd>/` where the
/// folder is the LOCAL date the segment STARTED; files are named `HH-mm-ss`. M5 adds .md
/// transcripts, `_day.json`, retention, and backup flags on top of this layout.
struct SegmentStore: Sendable {
    let rootDirectory: URL

    init(rootDirectory: URL? = nil) {
        self.rootDirectory = rootDirectory
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Sotto", isDirectory: true)
    }

    // Pinned per QA1480: unpinned formatters follow the device's calendar/locale, which can
    // produce Buddhist-era years or non-ASCII digits in what must be a literal ASCII layout.
    // TimeZone stays LOCAL on purpose — the spec files segments under the local date.
    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH-mm-ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        return formatter
    }()

    func pathsForSegment(startingAt date: Date) throws -> SegmentPaths {
        let dayDirectory = rootDirectory.appendingPathComponent(
            Self.dayFormatter.string(from: date), isDirectory: true)
        try FileManager.default.createDirectory(at: dayDirectory, withIntermediateDirectories: true)

        let base = Self.timeFormatter.string(from: date)
        var name = base
        var suffix = 2
        while FileManager.default.fileExists(
            atPath: dayDirectory.appendingPathComponent("\(name).caf").path)
            || FileManager.default.fileExists(
                atPath: dayDirectory.appendingPathComponent("\(name).m4a").path)
        {
            name = "\(base)-\(suffix)"
            suffix += 1
        }
        return SegmentPaths(
            cafURL: dayDirectory.appendingPathComponent("\(name).caf"),
            m4aURL: dayDirectory.appendingPathComponent("\(name).m4a"))
    }

    func freeDiskBytes() -> Int64 {
        // Root may not exist yet; capacity is a volume property, so ask the parent.
        let probe = FileManager.default.fileExists(atPath: rootDirectory.path)
            ? rootDirectory
            : rootDirectory.deletingLastPathComponent()
        let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    func orphanedCAFs() -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: rootDirectory, includingPropertiesForKeys: nil) else { return [] }
        return enumerator.compactMap { item in
            guard let url = item as? URL, url.pathExtension == "caf" else { return nil }
            return url
        }
    }
}
```

- [ ] **Step 4: Run tests to verify GREEN**

Expected: `** TEST SUCCEEDED **`, all green including 4 new (plus Task 1's factory now compiling if deferred).

- [ ] **Step 5: Commit**

```bash
git add Sotto/Segments SottoTests/SegmentStoreTests.swift
git commit -m "feat: SegmentStore date-folder layout, disk-free check, orphan scan"
```

---

### Task 3: RecorderStateMachine actor

**Files:**
- Create: `Sotto/Recorder/RecorderTypes.swift`
- Create: `Sotto/Recorder/RecorderStateMachine.swift`
- Modify: `SottoTests/Fakes.swift` (add `FakeSegmentWriter` + factory)
- Test: `SottoTests/RecorderStateMachineTests.swift`

**Interfaces:**
- Consumes: `SpeechDetecting`/`SpeechEvent` (existing), `SegmentWriting`/`SegmentWriterFactory`/`FinalizedSegment` (Task 1), `SegmentStore` (Task 2), `PreRollBuffer`, `VADConstants`, `AudioChunk`.
- Produces (Task 5 depends on these exactly):

```swift
enum RecorderState: String, Sendable, Equatable {
    case idle, listening, recording, silence, interrupted
}

struct RecorderSnapshot: Sendable, Equatable {
    var state: RecorderState
    var finalizedCount: Int
    var lastEvent: String?
}

struct RecorderConfig: Sendable {
    var silenceTimeout: TimeInterval = 45
    var minSegmentSpeechDuration: TimeInterval = 3
    var maxSegmentDuration: TimeInterval = 7_200
    var preRollCapacity: Int = VADConstants.sampleRate   // 1.0 s
    var minFreeDiskBytes: Int64 = 500_000_000
}

protocol SegmentRecording: Sendable {
    func beginListening() async -> RecorderSnapshot
    func process(_ chunk: AudioChunk) async -> RecorderSnapshot
    func finishAndFinalize() async -> RecorderSnapshot   // stop: finalize open segment → idle
    func markInterrupted() async -> RecorderSnapshot     // M3 wires callers
}

actor RecorderStateMachine: SegmentRecording {
    init(detector: any SpeechDetecting, writerFactory: any SegmentWriterFactory,
         store: SegmentStore, config: RecorderConfig = RecorderConfig())
    func setSegmentHandler(_ handler: @escaping @Sendable (FinalizedSegment) -> Void)
}
```

- [ ] **Step 1: Add fakes to `SottoTests/Fakes.swift`**

```swift
/// Records appended samples; finalize/discard bookkeeping for state-machine tests.
final class FakeSegmentWriter: SegmentWriting {
    private(set) var writtenSampleCount = 0
    private(set) var appendCalls: [Int] = []      // sample counts per append
    private(set) var finalized = false
    private(set) var discarded = false
    let m4aURL = URL(fileURLWithPath: "/tmp/fake-\(UUID().uuidString).m4a")

    func append(_ samples: [Float]) throws {
        appendCalls.append(samples.count)
        writtenSampleCount += samples.count
    }

    func finalize() throws -> URL {
        finalized = true
        return m4aURL
    }

    func discard() {
        discarded = true
    }
}

/// Hands out FakeSegmentWriters and remembers them for assertions.
final class FakeWriterFactory: SegmentWriterFactory, @unchecked Sendable {
    // @unchecked: mutated only from within the single recorder actor under test.
    private(set) var writers: [FakeSegmentWriter] = []
    private(set) var startDates: [Date] = []

    func makeWriter(startDate: Date) throws -> any SegmentWriting {
        let writer = FakeSegmentWriter()
        writers.append(writer)
        startDates.append(startDate)
        return writer
    }
}
```

- [ ] **Step 2: Write the failing tests — `SottoTests/RecorderStateMachineTests.swift`**

```swift
import Foundation
import Testing
@testable import Sotto

struct RecorderStateMachineTests {
    private func chunk() -> AudioChunk {
        AudioChunk(samples: [Float](repeating: 0, count: VADConstants.chunkSize), hostTime: 0)
    }

    private func makeMachine(
        script: [Int: SpeechEvent],
        config: RecorderConfig = RecorderConfig(),
        factory: FakeWriterFactory = FakeWriterFactory()
    ) -> (RecorderStateMachine, FakeWriterFactory) {
        let store = SegmentStore(rootDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent("RecorderTests-\(UUID().uuidString)"))
        let machine = RecorderStateMachine(
            detector: FakeSpeechDetector(script: script),
            writerFactory: factory, store: store, config: config)
        return (machine, factory)
    }

    @Test func speechStartOpensSegmentAndFlushesPreRoll() async throws {
        let (machine, factory) = makeMachine(script: [2: .speechStart(time: nil)])
        _ = await machine.beginListening()
        for _ in 0..<3 { _ = await machine.process(chunk()) }   // chunks 0,1 listening; 2 → start

        #expect(factory.writers.count == 1)
        // Pre-roll flush: chunks 0–2 were all appended to pre-roll before the event fired,
        // so the writer's FIRST append is the pre-roll snapshot (3 × 4096 = 12,288 samples,
        // under the 16,000 capacity).
        #expect(factory.writers[0].appendCalls.first == 3 * VADConstants.chunkSize)
        let snap = await machine.process(chunk())
        #expect(snap.state == .recording)
        #expect(factory.writers[0].appendCalls.count == 2)      // pre-roll + live chunk
    }

    @Test func speechEndEntersSilenceAndKeepsWriting() async throws {
        let (machine, factory) = makeMachine(script: [0: .speechStart(time: nil), 2: .speechEnd(time: nil)])
        _ = await machine.beginListening()
        for _ in 0..<3 { _ = await machine.process(chunk()) }
        let snap = await machine.process(chunk())               // chunk 3: in silence
        #expect(snap.state == .silence)
        // Silence chunks are still written (seamless if speech resumes). Append count is 4:
        // chunk 0 lives INSIDE the pre-roll flush (one append), then live chunks 1, 2, 3 —
        // chunk 2 carried the speechEnd but is still appended; chunk 3 is appended in silence.
        #expect(factory.writers[0].appendCalls.count == 4)
    }

    @Test func silenceTimeoutFinalizesAndReturnsToListening() async throws {
        var config = RecorderConfig()
        config.silenceTimeout = 1.0                              // 1 s ≈ 4 chunks of 256 ms
        config.minSegmentSpeechDuration = 0                      // don't trip the min guard here
        let (machine, factory) = makeMachine(
            script: [0: .speechStart(time: nil), 1: .speechEnd(time: nil)], config: config)
        _ = await machine.beginListening()
        var last = RecorderSnapshot(state: .idle, finalizedCount: 0, lastEvent: nil)
        for _ in 0..<8 { last = await machine.process(chunk()) }

        #expect(factory.writers[0].finalized)
        #expect(last.state == .listening)
        #expect(last.finalizedCount == 1)
    }

    @Test func speechResumeDuringSilenceReturnsToRecording() async throws {
        var config = RecorderConfig()
        config.silenceTimeout = 10
        let (machine, factory) = makeMachine(
            script: [0: .speechStart(time: nil), 1: .speechEnd(time: nil), 3: .speechStart(time: nil)],
            config: config)
        _ = await machine.beginListening()
        var last = RecorderSnapshot(state: .idle, finalizedCount: 0, lastEvent: nil)
        for _ in 0..<5 { last = await machine.process(chunk()) }
        #expect(last.state == .recording)
        #expect(!factory.writers[0].finalized)
        #expect(factory.writers.count == 1)                     // same segment, no split
    }

    @Test func shortSegmentIsDiscardedNotFinalized() async throws {
        var config = RecorderConfig()
        config.silenceTimeout = 0.5                              // 2 chunks
        config.minSegmentSpeechDuration = 3                      // speech here is ~0.25 s → discard
        let (machine, factory) = makeMachine(
            script: [0: .speechStart(time: nil), 1: .speechEnd(time: nil)], config: config)
        _ = await machine.beginListening()
        var last = RecorderSnapshot(state: .idle, finalizedCount: 0, lastEvent: nil)
        for _ in 0..<6 { last = await machine.process(chunk()) }

        #expect(factory.writers[0].discarded)
        #expect(!factory.writers[0].finalized)
        #expect(last.finalizedCount == 0)
        #expect(last.state == .listening)
    }

    @Test func maxSegmentDurationRotatesIntoNewSegmentWhileRecording() async throws {
        var config = RecorderConfig()
        config.maxSegmentDuration = 2.0                          // ≈ 8 chunks incl. pre-roll
        config.minSegmentSpeechDuration = 0
        let (machine, factory) = makeMachine(script: [0: .speechStart(time: nil)], config: config)
        _ = await machine.beginListening()
        var last = RecorderSnapshot(state: .idle, finalizedCount: 0, lastEvent: nil)
        for _ in 0..<12 { last = await machine.process(chunk()) }

        #expect(factory.writers.count == 2)                      // rotated exactly once so far
        #expect(factory.writers[0].finalized)
        #expect(!factory.writers[1].finalized)
        #expect(last.state == .recording)                        // still recording, new file
        #expect(last.finalizedCount == 1)
    }

    @Test func finishAndFinalizeClosesOpenSegment() async throws {
        var config = RecorderConfig()
        config.minSegmentSpeechDuration = 0
        let (machine, factory) = makeMachine(script: [0: .speechStart(time: nil)], config: config)
        _ = await machine.beginListening()
        for _ in 0..<3 { _ = await machine.process(chunk()) }
        let snap = await machine.finishAndFinalize()

        #expect(factory.writers[0].finalized)
        #expect(snap.state == .idle)
        #expect(snap.finalizedCount == 1)
    }

    @Test func diskGuardBlocksNewSegments() async throws {
        var config = RecorderConfig()
        config.minFreeDiskBytes = .max                           // impossible requirement
        let (machine, factory) = makeMachine(script: [0: .speechStart(time: nil)], config: config)
        _ = await machine.beginListening()
        let snap = await machine.process(chunk())

        #expect(factory.writers.isEmpty)
        #expect(snap.state == .listening)                        // stayed listening
        #expect(snap.lastEvent?.contains("disk") == true)
    }

    @Test func segmentHandlerReceivesFinalizedSegment() async throws {
        var config = RecorderConfig()
        config.silenceTimeout = 0.5
        config.minSegmentSpeechDuration = 0
        let (machine, _) = makeMachine(
            script: [0: .speechStart(time: nil), 1: .speechEnd(time: nil)], config: config)
        let received = Mutex<[FinalizedSegment]>([])
        await machine.setSegmentHandler { segment in
            received.withLock { $0.append(segment) }
        }
        _ = await machine.beginListening()
        for _ in 0..<6 { _ = await machine.process(chunk()) }

        let segments = received.withLock { $0 }
        #expect(segments.count == 1)
        #expect(segments[0].duration > 0)
    }

    @Test func markInterruptedFinalizesAndParksState() async throws {
        var config = RecorderConfig()
        config.minSegmentSpeechDuration = 0
        let (machine, factory) = makeMachine(script: [0: .speechStart(time: nil)], config: config)
        _ = await machine.beginListening()
        for _ in 0..<3 { _ = await machine.process(chunk()) }
        let snap = await machine.markInterrupted()

        #expect(factory.writers[0].finalized)
        #expect(snap.state == .interrupted)
        // Chunks arriving while interrupted are ignored:
        let after = await machine.process(chunk())
        #expect(after.state == .interrupted)
        #expect(factory.writers.count == 1)
    }
}
```

Add `import Synchronization` at the top of the test file (for `Mutex` in the handler test).

- [ ] **Step 3: `xcodegen generate`, run tests to verify RED**

Expected: BUILD FAILURE — `cannot find 'RecorderStateMachine' in scope`.

- [ ] **Step 4: Create `Sotto/Recorder/RecorderTypes.swift`**

```swift
import Foundation

/// The five recorder states from SPEC "State machine". `.idle` and `.interrupted` are
/// terminal-ish (chunks are ignored); the other three are the active listening loop.
enum RecorderState: String, Sendable, Equatable {
    case idle
    case listening
    case recording
    case silence
    case interrupted
}

struct RecorderSnapshot: Sendable, Equatable {
    var state: RecorderState
    var finalizedCount: Int
    var lastEvent: String?
}

struct RecorderConfig: Sendable {
    /// App-level conversation gap (SPEC default 45 s) — NOT the VAD's ~0.75 s hysteresis.
    var silenceTimeout: TimeInterval = 45
    var minSegmentSpeechDuration: TimeInterval = 3
    var maxSegmentDuration: TimeInterval = 7_200
    var preRollCapacity: Int = VADConstants.sampleRate   // 1.0 s
    var minFreeDiskBytes: Int64 = 500_000_000
}

/// Seam between the MainActor pipeline facade and the recorder actor.
protocol SegmentRecording: Sendable {
    func beginListening() async -> RecorderSnapshot
    func process(_ chunk: AudioChunk) async -> RecorderSnapshot
    /// Stop semantics: finalize any open segment, return to idle.
    func finishAndFinalize() async -> RecorderSnapshot
    /// Interruption semantics (M3 wires callers): finalize what exists, park.
    func markInterrupted() async -> RecorderSnapshot
}
```

- [ ] **Step 5: Create `Sotto/Recorder/RecorderStateMachine.swift`**

```swift
import Foundation

/// The heart of M2: consumes 256 ms chunks, drives the five-state machine, owns the
/// pre-roll buffer, the VAD detector, and the segment writer — all off the MainActor.
/// Silence timing is measured in SAMPLE COUNTS (chunks arrive continuously while the
/// mic is live), so transitions are deterministic and wall-clock-free.
actor RecorderStateMachine: SegmentRecording {
    private let detector: any SpeechDetecting
    private let writerFactory: any SegmentWriterFactory
    private let store: SegmentStore
    private let config: RecorderConfig

    private var state: RecorderState = .idle
    private var preRoll: PreRollBuffer
    private var writer: (any SegmentWriting)?
    private var segmentStartDate: Date?
    private var lastSpeechEndSampleCount = 0    // written samples at the most recent speechEnd
    private var samplesSinceLastSpeech = 0
    private var finalizedCount = 0
    private var lastEvent: String?
    private var segmentHandler: (@Sendable (FinalizedSegment) -> Void)?

    init(
        detector: any SpeechDetecting,
        writerFactory: any SegmentWriterFactory,
        store: SegmentStore,
        config: RecorderConfig = RecorderConfig()
    ) {
        self.detector = detector
        self.writerFactory = writerFactory
        self.store = store
        self.config = config
        self.preRoll = PreRollBuffer(capacity: config.preRollCapacity)
    }

    func setSegmentHandler(_ handler: @escaping @Sendable (FinalizedSegment) -> Void) {
        segmentHandler = handler
    }

    func beginListening() -> RecorderSnapshot {
        state = .listening
        lastEvent = nil
        return snapshot()
    }

    func process(_ chunk: AudioChunk) async -> RecorderSnapshot {
        guard state == .listening || state == .recording || state == .silence else {
            return snapshot()
        }

        let event: SpeechEvent?
        do {
            event = try await detector.process(chunk)
        } catch {
            lastEvent = "VAD error: \(error)"
            if state != .listening {
                write(chunk.samples)   // never drop audio mid-segment over a VAD hiccup
            } else {
                preRoll.append(chunk.samples)
            }
            return snapshot()
        }

        switch state {
        case .listening:
            preRoll.append(chunk.samples)
            if case .speechStart = event {
                openSegment()
            }

        case .recording:
            write(chunk.samples)
            if case .speechEnd = event {
                state = .silence
                samplesSinceLastSpeech = 0
                lastSpeechEndSampleCount = writer?.writtenSampleCount ?? 0
            }
            rotateIfBeyondMaxDuration()

        case .silence:
            write(chunk.samples)
            samplesSinceLastSpeech += chunk.samples.count
            if case .speechStart = event {
                state = .recording
            } else if secondsOf(samplesSinceLastSpeech) >= config.silenceTimeout {
                finalizeSegment()
            }
            rotateIfBeyondMaxDuration()

        case .idle, .interrupted:
            break
        }
        return snapshot()
    }

    func finishAndFinalize() async -> RecorderSnapshot {
        if writer != nil {
            if state == .recording {
                lastSpeechEndSampleCount = writer?.writtenSampleCount ?? 0
            }
            finalizeSegment()
        }
        state = .idle
        preRoll.removeAll()
        await detector.reset()
        return snapshot()
    }

    func markInterrupted() async -> RecorderSnapshot {
        if writer != nil {
            if state == .recording {
                lastSpeechEndSampleCount = writer?.writtenSampleCount ?? 0
            }
            finalizeSegment()
        }
        state = .interrupted
        preRoll.removeAll()
        await detector.reset()
        lastEvent = "Interrupted"
        return snapshot()
    }

    // MARK: - Segment lifecycle

    private func openSegment() {
        guard store.freeDiskBytes() >= config.minFreeDiskBytes else {
            lastEvent = "Low disk space — not recording"
            return
        }
        let startDate = Date()
        do {
            let newWriter = try writerFactory.makeWriter(startDate: startDate)
            writer = newWriter
            segmentStartDate = startDate
            lastSpeechEndSampleCount = 0
            samplesSinceLastSpeech = 0
            let flush = preRoll.snapshot()
            preRoll.removeAll()
            try newWriter.append(flush)
            state = .recording
            lastEvent = "Recording"
        } catch {
            writer = nil
            lastEvent = "Could not start segment: \(error)"
        }
    }

    private func write(_ samples: [Float]) {
        do {
            try writer?.append(samples)
        } catch {
            lastEvent = "Write failed: \(error)"
        }
    }

    private func rotateIfBeyondMaxDuration() {
        guard let writer,
              secondsOf(writer.writtenSampleCount) >= config.maxSegmentDuration else { return }
        // Force-finalize and continue seamlessly in a new segment (SPEC max-segment guard).
        let resumeState = state
        lastSpeechEndSampleCount = writer.writtenSampleCount
        finalizeSegment()
        openSegment()
        if writer != nil {
            state = resumeState == .silence ? .silence : .recording
        }
    }

    private func finalizeSegment() {
        guard let closing = writer, let startDate = segmentStartDate else { return }
        writer = nil
        segmentStartDate = nil
        state = .listening

        let speechDuration = secondsOf(lastSpeechEndSampleCount)
        if speechDuration < config.minSegmentSpeechDuration {
            closing.discard()
            lastEvent = "Discarded short segment (\(String(format: "%.1f", speechDuration)) s)"
            return
        }
        do {
            let url = try closing.finalize()
            finalizedCount += 1
            lastEvent = "Saved conversation"
            let segment = FinalizedSegment(
                audioURL: url,
                startDate: startDate,
                duration: secondsOf(closing.writtenSampleCount),
                speechDuration: speechDuration)
            segmentHandler?(segment)
        } catch {
            lastEvent = "Finalize failed: \(error)"
        }
    }

    private func secondsOf(_ samples: Int) -> TimeInterval {
        Double(samples) / Double(VADConstants.sampleRate)
    }

    private func snapshot() -> RecorderSnapshot {
        RecorderSnapshot(state: state, finalizedCount: finalizedCount, lastEvent: lastEvent)
    }
}
```

- [ ] **Step 6: Run tests to verify GREEN**

Expected: `** TEST SUCCEEDED **`, all green including 10 new. If an assertion about exact append counts fails, TRACE the machine by hand against the test's script before touching either — the tests encode the spec's semantics (silence keeps writing; pre-roll flush includes the triggering chunk; rotation preserves state) and the machine must match them, not vice versa. Report any test you had to change and why.

- [ ] **Step 7: Commit**

```bash
git add Sotto/Recorder SottoTests/RecorderStateMachineTests.swift SottoTests/Fakes.swift
git commit -m "feat: five-state RecorderStateMachine with guards and deterministic silence timing"
```

---

### Task 4: HeartbeatStore + OrphanSalvager

**Files:**
- Create: `Sotto/Recorder/HeartbeatStore.swift`
- Test: `SottoTests/HeartbeatTests.swift`

**Interfaces:**
- Consumes: `SegmentStore.orphanedCAFs()` (Task 2), `CAFSegmentWriter.transcodeToM4A` (Task 1), `RecorderState` (Task 3).
- Produces:

```swift
struct HeartbeatStore: Sendable {
    struct Heartbeat: Codable, Equatable { let state: String; let timestamp: Date }
    let fileURL: URL
    init(fileURL: URL? = nil)                    // default: Application Support/heartbeat.json
    func record(_ state: RecorderState)
    func read() -> Heartbeat?
    func clear()
    var indicatesUncleanShutdown: Bool { get }   // read() exists && state != "idle"
}

enum OrphanSalvager {
    /// Transcodes every orphaned CAF to .m4a next to it; deletes the CAF (also on
    /// unreadable/corrupt CAFs — nothing recoverable there). Returns salvaged m4a URLs.
    static func salvage(store: SegmentStore) -> [URL]
}
```

- [ ] **Step 1: Write the failing tests — `SottoTests/HeartbeatTests.swift`**

```swift
import AVFoundation
import Foundation
import Testing
@testable import Sotto

struct HeartbeatTests {
    private func tempHeartbeat() -> HeartbeatStore {
        HeartbeatStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("hb-\(UUID().uuidString).json"))
    }

    @Test func recordReadClearRoundTrip() {
        let store = tempHeartbeat()
        #expect(store.read() == nil)
        store.record(.listening)
        #expect(store.read()?.state == "listening")
        #expect(store.indicatesUncleanShutdown)
        store.record(.idle)
        #expect(!store.indicatesUncleanShutdown)
        store.clear()
        #expect(store.read() == nil)
    }

    @Test func salvageTranscodesOrphanedCAF() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SalvageTests-\(UUID().uuidString)")
        let store = SegmentStore(rootDirectory: root)
        let paths = try store.pathsForSegment(startingAt: Date())
        do {
            let writer = try CAFSegmentWriter(cafURL: paths.cafURL, m4aURL: paths.m4aURL)
            let samples = (0..<VADConstants.sampleRate).map {
                sinf(2 * .pi * 300 * Float($0) / Float(VADConstants.sampleRate)) * 0.4
            }
            try writer.append(samples)
            // Crash: writer dropped, never finalized.
        }

        let salvaged = OrphanSalvager.salvage(store: store)

        #expect(salvaged == [paths.m4aURL])
        #expect(!FileManager.default.fileExists(atPath: paths.cafURL.path))
        let file = try AVAudioFile(forReading: paths.m4aURL)
        #expect(file.length > 0)
    }

    @Test func salvageDropsUnreadableCAF() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SalvageTests-\(UUID().uuidString)")
        let store = SegmentStore(rootDirectory: root)
        let paths = try store.pathsForSegment(startingAt: Date())
        FileManager.default.createFile(atPath: paths.cafURL.path, contents: Data([0x00, 0x01]))

        let salvaged = OrphanSalvager.salvage(store: store)

        #expect(salvaged.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: paths.cafURL.path))   // junk removed
    }
}
```

- [ ] **Step 2: `xcodegen generate`, run tests to verify RED**

Expected: BUILD FAILURE — `cannot find 'HeartbeatStore' in scope`.

- [ ] **Step 3: Create `Sotto/Recorder/HeartbeatStore.swift`**

```swift
import Foundation

/// Tiny state file persisted on every recorder transition (SPEC "Unclean shutdown
/// detection"): on launch, heartbeat says "listening" but we're cold-starting → the app
/// died. M5 records the gap in `_day.json`; M2 salvages the audio and surfaces a banner.
struct HeartbeatStore: Sendable {
    struct Heartbeat: Codable, Equatable {
        let state: String
        let timestamp: Date
    }

    let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let support = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask)[0]
            try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            self.fileURL = support.appendingPathComponent("heartbeat.json")
        }
    }

    func record(_ state: RecorderState) {
        let heartbeat = Heartbeat(state: state.rawValue, timestamp: Date())
        guard let data = try? JSONEncoder().encode(heartbeat) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    func read() -> Heartbeat? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(Heartbeat.self, from: data)
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    var indicatesUncleanShutdown: Bool {
        guard let heartbeat = read() else { return false }
        return heartbeat.state != RecorderState.idle.rawValue
    }
}

enum OrphanSalvager {
    /// Salvage everything readable from CAFs a dead process left behind; remove the CAFs
    /// either way (an unreadable CAF has nothing to recover).
    static func salvage(store: SegmentStore) -> [URL] {
        var salvaged: [URL] = []
        for caf in store.orphanedCAFs() {
            let m4a = caf.deletingPathExtension().appendingPathExtension("m4a")
            do {
                try CAFSegmentWriter.transcodeToM4A(caf: caf, m4a: m4a)
                salvaged.append(m4a)
            } catch {
                try? FileManager.default.removeItem(at: m4a)   // partial output, if any
            }
            try? FileManager.default.removeItem(at: caf)
        }
        return salvaged
    }
}
```

- [ ] **Step 4: Run tests to verify GREEN**

Expected: `** TEST SUCCEEDED **`, all green including 3 new.

- [ ] **Step 5: Commit**

```bash
git add Sotto/Recorder/HeartbeatStore.swift SottoTests/HeartbeatTests.swift
git commit -m "feat: heartbeat unclean-shutdown detection and orphaned-CAF salvage"
```

---

### Task 5: Rewire ListeningPipeline + UI onto the recorder

**Files:**
- Modify: `Sotto/Pipeline/ListeningPipeline.swift`
- Modify: `Sotto/App/ContentView.swift`
- Modify: `SottoTests/Fakes.swift` (add `FakeRecorder`)
- Modify: `SottoTests/ListeningPipelineTests.swift` (rewrite around the recorder seam)

**Interfaces:**
- Consumes: `SegmentRecording`, `RecorderSnapshot`, `RecorderState`, `RecorderStateMachine`, `RecorderConfig` (Task 3), `HeartbeatStore`/`OrphanSalvager` (Task 4), `SegmentStore`/`CAFSegmentWriterFactory` (Tasks 1–2).
- Produces: `ListeningPipeline` v2 — `init(source: any AudioSource, recorder: any SegmentRecording, heartbeat: HeartbeatStore? = nil)`; `Status` becomes `{ idle, starting, listening, recording, silence }`; `finalizedCount: Int` published. **Removed:** `detector` dependency, `preRollSnapshot()`, `preRollSamples` parameter (the recorder owns pre-roll now). Everything else (start/stop/queued-stop/deinit/waitUntilDrained contracts) is preserved.

- [ ] **Step 1: Add `FakeRecorder` to `SottoTests/Fakes.swift`**

```swift
/// Scriptable recorder seam for pipeline tests: returns a scripted state per chunk index
/// and tracks ordering invariants (no chunk may be processed after finishAndFinalize).
actor FakeRecorder: SegmentRecording {
    private let stateScript: [Int: RecorderState]
    private var index = 0
    private var finished = false
    private(set) var processedChunks = 0
    private(set) var processedAfterFinish = 0
    private(set) var finishCount = 0
    private(set) var beginCount = 0

    init(stateScript: [Int: RecorderState] = [:]) {
        self.stateScript = stateScript
    }

    func beginListening() -> RecorderSnapshot {
        beginCount += 1
        finished = false
        index = 0
        return RecorderSnapshot(state: .listening, finalizedCount: 0, lastEvent: nil)
    }

    func process(_ chunk: AudioChunk) -> RecorderSnapshot {
        processedChunks += 1
        if finished { processedAfterFinish += 1 }
        defer { index += 1 }
        let state = stateScript[index] ?? .listening
        return RecorderSnapshot(state: state, finalizedCount: 0, lastEvent: nil)
    }

    func finishAndFinalize() -> RecorderSnapshot {
        finished = true
        finishCount += 1
        return RecorderSnapshot(state: .idle, finalizedCount: 0, lastEvent: nil)
    }

    func markInterrupted() -> RecorderSnapshot {
        RecorderSnapshot(state: .interrupted, finalizedCount: 0, lastEvent: nil)
    }
}
```

- [ ] **Step 2: Rewrite `Sotto/Pipeline/ListeningPipeline.swift`**

Full new file content (the transition machinery is UNCHANGED from the current file — only the recorder seam replaces detector/preRoll; copy the current file and apply exactly these deltas, or transcribe this whole listing):

```swift
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
    }

    private(set) var status: Status = .idle
    private(set) var eventLog: [String] = []
    private(set) var finalizedCount = 0

    private let source: any AudioSource
    private let recorder: any SegmentRecording
    private let heartbeat: HeartbeatStore?
    private var pumpTask: Task<Void, Never>?
    private var isTransitioning = false
    private var queuedStops: [CheckedContinuation<Void, Never>] = []

    init(
        source: any AudioSource,
        recorder: any SegmentRecording,
        heartbeat: HeartbeatStore? = nil
    ) {
        self.source = source
        self.recorder = recorder
        self.heartbeat = heartbeat
    }

    deinit {
        // Belt-and-braces: if an owner drops the pipeline without stop(), stop the source
        // so the stream finishes and the (weak-self) pump exits — otherwise the live audio
        // stack (engine, tap, VAD) would keep running with no reachable owner.
        let source = self.source
        Task.detached {
            await source.stop()
        }
    }

    func start() async {
        guard status == .idle, !isTransitioning else { return }
        isTransitioning = true
        status = .starting   // truthful: no audio flows until source.start() succeeds
        do {
            let stream = try await source.start()
            let snapshot = await recorder.beginListening()
            apply(snapshot)
            eventLog.append("Listening…")
            pumpTask = Task { [weak self] in
                for await chunk in stream {
                    await self?.handle(chunk)
                }
            }
        } catch {
            status = .idle
            eventLog.append("Start failed: \(error)")
        }
        isTransitioning = false
        if !queuedStops.isEmpty {
            if status != .idle {
                await performStop()      // drains, finalizes, idles, then resumes the waiters
            } else {
                resumeQueuedStops()      // start failed: already idle, nothing to stop
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
        await performStop()
    }

    /// Test hook: waits for the pump task to finish draining a closed stream.
    func waitUntilDrained() async {
        await pumpTask?.value
    }

    private func performStop() async {
        isTransitioning = true
        await source.stop()          // finish the stream: no new chunks after this
        await pumpTask?.value        // drain chunks already in flight to quiescence
        pumpTask = nil
        let snapshot = await recorder.finishAndFinalize()
        apply(snapshot)
        status = .idle
        heartbeat?.record(.idle)
        eventLog.append("Stopped")
        isTransitioning = false
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

    private func apply(_ snapshot: RecorderSnapshot) {
        let newStatus: Status
        switch snapshot.state {
        case .idle, .interrupted: newStatus = .idle
        case .listening: newStatus = .listening
        case .recording: newStatus = .recording
        case .silence: newStatus = .silence
        }
        if status != newStatus {
            status = newStatus
            heartbeat?.record(snapshot.state)
        }
        finalizedCount = snapshot.finalizedCount
        if let event = snapshot.lastEvent, event != eventLog.last {
            eventLog.append(event)
        }
    }
}
```

(`apply` is only ever called with recorder snapshots — from `start()` right after `beginListening()`, from `handle()`, and from `performStop()` — so the recorder's state is authoritative at each of those points; there is no path where a stale chunk snapshot races the transition flags, because the pump is drained before `finishAndFinalize()` runs.)

- [ ] **Step 3: Rewrite `SottoTests/ListeningPipelineTests.swift`**

Replace the whole file:

```swift
import Testing
@testable import Sotto

@MainActor
struct ListeningPipelineTests {
    @Test func recorderStatesDriveStatus() async throws {
        let source = FakeAudioSource()
        let recorder = FakeRecorder(stateScript: [2: .recording, 5: .silence])
        let pipeline = ListeningPipeline(source: source, recorder: recorder)

        await pipeline.start()
        #expect(pipeline.status == .listening)
        await source.emitSilentChunks(count: 6)
        await source.finish()
        await pipeline.waitUntilDrained()

        #expect(pipeline.status == .silence)   // last scripted state (index 5)
        await pipeline.stop()
        #expect(pipeline.status == .idle)
    }

    @Test func stopDrainsPumpBeforeFinalize() async throws {
        let source = FakeAudioSource()
        let recorder = FakeRecorder()
        let pipeline = ListeningPipeline(source: source, recorder: recorder)

        await pipeline.start()
        await source.emitSilentChunks(count: 3)
        // Deliberately no waitUntilDrained(): stop() itself must drain, THEN finalize.
        await pipeline.stop()

        #expect(await recorder.processedChunks == 3)
        #expect(await recorder.processedAfterFinish == 0)   // drain-before-finalize invariant
        #expect(await recorder.finishCount == 1)
        #expect(pipeline.status == .idle)
    }

    @Test func startIsIdempotentWhileActive() async throws {
        let source = FakeAudioSource()
        let pipeline = ListeningPipeline(source: source, recorder: FakeRecorder())

        await pipeline.start()
        await pipeline.start()   // second start while listening must be a no-op
        #expect(pipeline.status == .listening)
        #expect(await source.startCallCount == 1)
        await pipeline.stop()
    }

    @Test func concurrentStartsOnlyStartSourceOnce() async throws {
        let source = FakeAudioSource()
        let pipeline = ListeningPipeline(source: source, recorder: FakeRecorder())

        async let first: Void = pipeline.start()
        async let second: Void = pipeline.start()
        _ = await (first, second)

        #expect(await source.startCallCount == 1)
        #expect(pipeline.status == .listening)
        await pipeline.stop()
    }

    @Test func statusIsStartingWhileSourceStartIsInFlight() async throws {
        let source = SlowStartAudioSource()
        let pipeline = ListeningPipeline(source: source, recorder: FakeRecorder())

        async let starting: Void = pipeline.start()
        await source.waitUntilStartRequested()
        #expect(pipeline.status == .starting)
        await source.releaseStart()
        await starting
        #expect(pipeline.status == .listening)
        await pipeline.stop()
    }

    @Test func queuedStopReturnsOnlyOncePipelineIsIdle() async throws {
        let source = SlowStartAudioSource()
        let recorder = FakeRecorder()
        let pipeline = ListeningPipeline(source: source, recorder: recorder)

        async let starting: Void = pipeline.start()
        await source.waitUntilStartRequested()
        async let stopping: Void = pipeline.stop()
        for _ in 0..<5 { await Task.yield() }
        await source.releaseStart()
        await stopping
        #expect(pipeline.status == .idle)
        #expect(await recorder.finishCount == 1)
        await starting
    }

    @Test func startStopStartBurstEndsIdleWithoutOrphanedPump() async throws {
        let source = SlowStartAudioSource()
        let recorder = FakeRecorder()
        let pipeline = ListeningPipeline(source: source, recorder: recorder)

        async let firstStart: Void = pipeline.start()
        await source.waitUntilStartRequested()
        async let stopping: Void = pipeline.stop()
        async let secondStart: Void = pipeline.start()
        for _ in 0..<5 { await Task.yield() }
        await source.releaseStart()
        _ = await (firstStart, stopping, secondStart)

        #expect(pipeline.status == .idle)
        await source.emitSilentChunks(count: 2)
        for _ in 0..<10 { await Task.yield() }
        #expect(await recorder.processedAfterFinish == 0)   // no orphaned pump feeding chunks
    }

    @Test func droppingPipelineWithoutStopTearsDownSource() async throws {
        let source = FakeAudioSource()
        var pipeline: ListeningPipeline? = ListeningPipeline(source: source, recorder: FakeRecorder())
        await pipeline?.start()
        await source.emitSilentChunks(count: 2)

        pipeline = nil   // owner forgot stop(); deinit must still tear down the source

        var stopped = false
        for _ in 0..<50 where !stopped {
            try await Task.sleep(for: .milliseconds(10))
            stopped = await source.stopCallCount > 0
        }
        #expect(stopped)
    }
}
```

- [ ] **Step 4: `xcodegen generate`, run tests to verify RED**

Expected: BUILD FAILURE — pipeline still has the old `init(source:detector:preRollSamples:)`; ContentView also fails until Step 5. That's the red for this rewiring.

- [ ] **Step 5: Update `Sotto/App/ContentView.swift`**

Full new file content:

```swift
import SwiftUI

struct ContentView: View {
    @State private var pipeline: ListeningPipeline?
    @State private var setupError: String?
    @State private var recoveryNotice: String?

    var body: some View {
        NavigationStack {
            Group {
                if let setupError {
                    ContentUnavailableView(
                        "Setup failed",
                        systemImage: "exclamationmark.triangle",
                        description: Text(setupError))
                } else if let pipeline {
                    PipelineView(pipeline: pipeline, recoveryNotice: recoveryNotice)
                } else {
                    ProgressView("Loading VAD model…")
                }
            }
            .navigationTitle("Sotto")
        }
        .task { await setUp() }
    }

    @MainActor
    private func setUp() async {
        guard pipeline == nil, setupError == nil else { return }
        guard let modelURL = Bundle.main.url(
            forResource: SileroSpeechDetector.modelResourceName,
            withExtension: "mlmodelc")
        else {
            setupError = "VAD model missing from app bundle"
            return
        }

        let store = SegmentStore()
        let heartbeat = HeartbeatStore()

        // Unclean-shutdown detection + salvage (SPEC "heartbeat/unclean-shutdown detection").
        if heartbeat.indicatesUncleanShutdown {
            let salvaged = await Task.detached { OrphanSalvager.salvage(store: store) }.value
            recoveryNotice = salvaged.isEmpty
                ? "Listening stopped unexpectedly last session."
                : "Listening stopped unexpectedly — recovered \(salvaged.count) unfinished recording(s)."
            heartbeat.clear()
        }

        do {
            // CoreML load/compile can take hundreds of ms (seconds on a cold cache) —
            // off the MainActor so the loading indicator actually renders and animates.
            let detector = try await Task.detached(priority: .userInitiated) {
                try SileroSpeechDetector(modelURL: modelURL)
            }.value
            let recorder = RecorderStateMachine(
                detector: detector,
                writerFactory: CAFSegmentWriterFactory(store: store),
                store: store)
            pipeline = ListeningPipeline(
                source: PhoneMicAudioSource(), recorder: recorder, heartbeat: heartbeat)
        } catch {
            setupError = String(describing: error)
        }
    }
}

private struct PipelineView: View {
    let pipeline: ListeningPipeline
    let recoveryNotice: String?

    var body: some View {
        VStack(spacing: 24) {
            if let recoveryNotice {
                Text(recoveryNotice)
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .padding(.horizontal)
            }

            Text(statusLabel)
                .font(.largeTitle.bold())
                .foregroundStyle(statusColor)

            Text("Conversations: \(pipeline.finalizedCount)")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Button(pipeline.status == .idle ? "Start Listening" : "Stop") {
                Task {
                    if pipeline.status == .idle {
                        await pipeline.start()
                    } else {
                        await pipeline.stop()
                    }
                }
            }
            .buttonStyle(.borderedProminent)

            List(Array(pipeline.eventLog.enumerated().reversed()), id: \.offset) { _, line in
                Text(line)
                    .font(.footnote.monospaced())
            }
            .listStyle(.plain)
        }
        .padding(.top, 24)
    }

    private var statusLabel: String {
        switch pipeline.status {
        case .idle: "Idle"
        case .starting: "Starting…"
        case .listening: "Listening"
        case .recording: "Recording"
        case .silence: "Silence"
        }
    }

    private var statusColor: Color {
        switch pipeline.status {
        case .idle: .secondary
        case .starting: .secondary
        case .listening: .green
        case .recording: .red
        case .silence: .orange
        }
    }
}
```

- [ ] **Step 6: Run the full suite**

Expected: `** TEST SUCCEEDED **`, all green (8 rewritten pipeline tests replace the previous 10; the two pre-roll-specific tests are gone — that behavior now lives in `RecorderStateMachineTests.speechStartOpensSegmentAndFlushesPreRoll`). Zero warnings.

- [ ] **Step 7: Commit**

```bash
git add Sotto/Pipeline/ListeningPipeline.swift Sotto/App/ContentView.swift SottoTests/Fakes.swift SottoTests/ListeningPipelineTests.swift
git commit -m "feat: wire pipeline and UI onto RecorderStateMachine with heartbeat"
```

---

### Task 6: End-to-end integration test + simulator run

**Files:**
- Test: `SottoTests/RecorderIntegrationTests.swift`

**Interfaces:**
- Consumes: everything. This is the whole-stack proof: real `SileroSpeechDetector` (bundled model), real `RecorderStateMachine`, real `CAFSegmentWriter` → a genuine `.m4a` on disk from synthetic speech.

- [ ] **Step 1: Write the integration test**

Reuse the synthetic speech-like signal proven in `SileroSpeechDetectorTests.speechLikeSignalTriggersSpeechStart` (read that test first — 180 Hz sawtooth + harmonics with 3–6 Hz AM, normalized ±0.5, detector threshold 0.3; transcribe its generator here rather than inventing a new one).

```swift
import AVFoundation
import Foundation
import Testing
@testable import Sotto

struct RecorderIntegrationTests {
    @Test func syntheticSpeechProducesRealM4ASegment() async throws {
        let modelURL = try #require(Bundle.main.url(
            forResource: SileroSpeechDetector.modelResourceName, withExtension: "mlmodelc"))
        let detector = try SileroSpeechDetector(modelURL: modelURL, threshold: 0.3)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecorderIntegration-\(UUID().uuidString)")
        let store = SegmentStore(rootDirectory: root)

        var config = RecorderConfig()
        config.silenceTimeout = 1.0
        config.minSegmentSpeechDuration = 0.5
        let machine = RecorderStateMachine(
            detector: detector,
            writerFactory: CAFSegmentWriterFactory(store: store),
            store: store, config: config)

        _ = await machine.beginListening()

        // ~2 s of speech-like audio in 4096-sample chunks (generator per the detector test):
        let speech = makeSpeechLikeSignal(seconds: 2.0)
        var last = RecorderSnapshot(state: .idle, finalizedCount: 0, lastEvent: nil)
        for start in stride(from: 0, to: speech.count - VADConstants.chunkSize, by: VADConstants.chunkSize) {
            let chunk = Array(speech[start..<start + VADConstants.chunkSize])
            last = await machine.process(AudioChunk(samples: chunk, hostTime: 0))
        }
        #expect(last.state == .recording || last.state == .silence)

        // Silence until finalize: the VAD's own ~0.75 s hysteresis must elapse BEFORE the
        // machine's 1 s timeout even starts counting, so allow ~3 s of zero chunks:
        for _ in 0..<12 {
            last = await machine.process(AudioChunk(
                samples: [Float](repeating: 0, count: VADConstants.chunkSize), hostTime: 0))
        }

        #expect(last.finalizedCount == 1)
        #expect(last.state == .listening)
        let m4as = try FileManager.default.subpathsOfDirectory(atPath: root.path)
            .filter { $0.hasSuffix(".m4a") }
        #expect(m4as.count == 1)
        let file = try AVAudioFile(forReading: root.appendingPathComponent(m4as[0]))
        let duration = Double(file.length) / file.processingFormat.sampleRate
        #expect(duration > 2.0)   // speech + pre-roll + trailing silence
        // No CAF left behind:
        let cafs = try FileManager.default.subpathsOfDirectory(atPath: root.path)
            .filter { $0.hasSuffix(".caf") }
        #expect(cafs.isEmpty)
    }
}
```

(`makeSpeechLikeSignal(seconds:)` — extract the existing generator from `SileroSpeechDetectorTests` into a shared internal helper in that test file, or duplicate the ~10-line generator here with a comment pointing at the original; implementer's choice, note it.)

- [ ] **Step 2: `xcodegen generate`, run the new test alone first**

Run: `xcodebuild test -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone Air' -only-testing:SottoTests/RecorderIntegrationTests 2>&1 | tail -5`
Expected: PASS. If the VAD never fires or the silence timeout math is off, DIAGNOSE with the snapshot's `lastEvent`/state trace — do not loosen the assertions to force green; report BLOCKED with the trace if the pipeline genuinely misbehaves.

- [ ] **Step 3: Full suite**

Expected: `** TEST SUCCEEDED **`, all green, zero warnings.

- [ ] **Step 4: Commit**

```bash
git add SottoTests/RecorderIntegrationTests.swift SottoTests/SileroSpeechDetectorTests.swift
git commit -m "test: whole-stack integration — synthetic speech to real m4a segment"
```

---

## Post-plan verification (controller, after all tasks)

Rebuild, reinstall, relaunch on the iPhone Air simulator, screenshot (Idle + Conversations: 0). Live speech → Recording → Silence → 45 s → saved segment remains a human test; note that **Stop also finalizes**, so the user can verify a segment lands in `Documents/Sotto/<date>/` (via `xcrun simctl get_app_container "iPhone Air" com.decanlys.Sotto data`) right after talking briefly and tapping Stop — no 45 s wait needed.

## Self-review notes

- Spec M2 coverage: five states ✓ (interrupted parked, wired by M3); 45 s app-level silence timeout ✓ (sample-count based); guards min 3 s ✓ / max 2 h rotate-and-continue ✓ / disk 500 MB ✓; crash-safe writer via CAF→m4a ✓ (spec option 2); heartbeat + unclean-shutdown detection + salvage ✓; Stop semantics (finalize current segment first) ✓; "audio keeps being written" through Silence ✓; pre-roll flush on speechStart ✓. Deferred per spec: `.md` placeholder + `_day.json` + gap entries (M5); transcription enqueue consumes `setSegmentHandler` (M4); Data Protection + backup-exclusion flags (M5); Live Activity + interruption *sources* (M3 — the machine's `markInterrupted()` is ready).
- Type consistency: `SegmentRecording` methods used by pipeline = declared set; `RecorderSnapshot(state:finalizedCount:lastEvent:)` argument order consistent across tests; `FakeSpeechDetector(script:)` reused as-is; `CAFSegmentWriterFactory(store:)` matches Task 2's store.
- Known judgment calls an executor must not "fix": silence chunks are written to the file (spec-mandated); the min-segment check uses SPEECH duration (start→last speechEnd), not file duration; rotation continues in the SAME state without pre-roll (live audio is continuous).

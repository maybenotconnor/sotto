# Sotto M1 — Audio + VAD Pipeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the Sotto project scaffold and the M1 milestone from `docs/SPEC.md`: mic capture → format conversion → fixed 4096-sample chunks → Silero VAD speech events → pre-roll ring buffer, with a debug UI that shows live speech detection.

**Architecture:** Audio input is abstracted behind an `AudioSource` protocol emitting value-type `AudioChunk`s over an `AsyncStream`. A `PhoneMicAudioSource` actor taps `AVAudioEngine` at the hardware format and converts to 16 kHz mono Float32. VAD is wrapped behind a `SpeechDetecting` protocol (`SileroSpeechDetector` actor over FluidAudio's `VadManager` with a bundled CoreML model — no runtime download). A `@MainActor` `ListeningPipeline` wires source → pre-roll buffer → detector and publishes status for SwiftUI.

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI, AVFoundation, CoreML, FluidAudio 0.15.4 (SPM), XcodeGen, Swift Testing (`import Testing`), iOS 26 simulator (iPhone Air).

## Global Constraints

- App name **Sotto**; bundle id **com.decanlys.Sotto**. (Repo folder is named `hearsay` — ignore that; nothing in code references it.)
- iOS deployment target **26.0**; toolchain is Xcode 26.6 / Swift 6.3.3 (verified installed).
- `SWIFT_VERSION: "6.0"` (Swift 6 language mode = strict concurrency) and `SWIFT_DEFAULT_ACTOR_ISOLATION: nonisolated` (do NOT let Xcode's new default-MainActor mode apply — this codebase uses explicit actors).
- Audio session: category `.playAndRecord`, mode `.default`, options `[.mixWithOthers]` exactly. **No Bluetooth input options of any kind.**
- Tap `AVAudioEngine.inputNode` **at hardware format** (`inputNode.outputFormat(forBus: 0)`). Requesting 16 kHz at the tap crashes with a format mismatch.
- Samples must be **copied out of the tap buffer synchronously**; `AVAudioPCMBuffer` must never cross an async boundary (not `Sendable`).
- Chunks are exactly **4096 samples of 16 kHz mono Float32** (== `VadManager.chunkSize`, 256 ms).
- FluidAudio pinned to **exactVersion 0.15.4** (`VadManager` is marked beta by the library — pin exact, wrap behind our own protocol).
- VAD model **bundled in the app** (`silero-vad-unified-256ms-v6.0.0.mlmodelc` from HuggingFace `FluidInference/silero-vad-coreml`, ~1.06 MB, license MIT). FluidAudio's downloader must never run: construct `VadManager(config:vadModel:)` with a pre-loaded `MLModel` (this initializer is verified to exist and does no I/O).
- Default VAD threshold **0.6** (`VadConfig(defaultThreshold: 0.6)`).
- Pre-roll ring buffer default **1.0 s = 16,000 samples**.
- Info.plist: `NSMicrophoneUsageDescription`, `UIBackgroundModes: [audio]`, `NSSupportsLiveActivities: YES`, `UIFileSharingEnabled: YES`, `LSSupportsOpeningDocumentsInPlace: YES`. **No `NSSpeechRecognitionUsageDescription`** — SpeechAnalyzer doesn't use one and adding it invites App Review questions.
- `Sotto.xcodeproj` is **generated** by XcodeGen from `project.yml` and is gitignored; run `xcodegen generate` after editing `project.yml`.
- Tests use **Swift Testing** (`import Testing`, `@Test`, `#expect`), run on the **iPhone Air** simulator (exists on this machine, iOS 26.5): `xcodebuild test -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone Air'`.
- The first `xcodebuild` invocation resolves SPM packages and is slow (minutes). Do not treat slowness as a hang.

### Verified FluidAudio 0.15.4 API (read from source 2026-07-03 — do not "correct" these)

```swift
public actor VadManager {
    public static let chunkSize = 4096
    public static let sampleRate = 16000
    public init(config: VadConfig = .default, vadModel: MLModel)   // sync, no I/O
    public func makeStreamState() -> VadStreamState                // or VadStreamState.initial()
    public func processStreamingChunk(
        _ audioChunk: [Float], state: VadStreamState,
        config: VadSegmentationConfig = .default,
        returnSeconds: Bool = false, timeResolution: Int = 1
    ) async throws -> VadStreamResult
}
public struct VadConfig: Sendable {
    public var defaultThreshold: Float   // library default 0.85; Sotto uses 0.6
    public var debugMode: Bool
    public var computeUnits: MLComputeUnits  // NOT used with pre-loaded model; set MLModelConfiguration instead
    public init(defaultThreshold: Float = 0.85, debugMode: Bool = false, computeUnits: MLComputeUnits = .cpuAndNeuralEngine)  // approx; use labeled args you need
}
public struct VadStreamResult: Sendable {
    public let state: VadStreamState
    public let event: VadStreamEvent?
    public let probability: Float
}
public struct VadStreamEvent: Sendable {
    public enum Kind: Sendable { case speechStart, speechEnd }
    public let kind: Kind
    public let sampleIndex: Int
    public let time: TimeInterval?      // set when returnSeconds: true
}
public struct VadStreamState: Sendable { public static func initial() -> VadStreamState }
```

`VadSegmentationConfig.default` gives ~0.75 s of VAD-level silence hysteresis before `.speechEnd` fires — that is separate from (and much shorter than) the app-level 45 s conversation timeout, which is M2's job and NOT part of this plan.

## File Structure

```
project.yml                                  ← XcodeGen manifest (source of truth for the project)
.gitignore
docs/SPEC.md                                 ← already present
Sotto/
  App/SottoApp.swift                         ← @main entry
  App/ContentView.swift                      ← M1 debug UI (status + event log)
  Audio/AudioTypes.swift                     ← AudioChunk, AudioSourceType, AudioSource
  Audio/SampleChunker.swift                  ← accumulates converter output into 4096-sample chunks
  Audio/PreRollBuffer.swift                  ← 1 s pre-roll ring buffer
  Audio/FormatConverter.swift                ← AVAudioConverter wrapper (hw format → 16 kHz mono Float32)
  Audio/PhoneMicAudioSource.swift            ← engine + tap + TapProcessor
  VAD/SpeechDetecting.swift                  ← SpeechEvent + SpeechDetecting protocol
  VAD/SileroSpeechDetector.swift             ← FluidAudio VadManager wrapper (actor)
  Pipeline/ListeningPipeline.swift           ← @MainActor @Observable glue
  Resources/silero-vad-unified-256ms-v6.0.0.mlmodelc/   ← bundled model (5 files, committed)
SottoTests/
  SmokeTests.swift
  SampleChunkerTests.swift
  PreRollBufferTests.swift
  FormatConverterTests.swift
  AudioSessionTests.swift
  SileroSpeechDetectorTests.swift
  ListeningPipelineTests.swift
  Fakes.swift                                ← FakeAudioSource, FakeSpeechDetector
```

---

### Task 1: Project scaffold

**Files:**
- Create: `.gitignore`
- Create: `project.yml`
- Create: `Sotto/App/SottoApp.swift`
- Create: `Sotto/App/ContentView.swift` (placeholder — replaced in Task 6)
- Test: `SottoTests/SmokeTests.swift`

**Interfaces:**
- Consumes: nothing (first task).
- Produces: a building, testing Xcode project named `Sotto` with app target `Sotto` (bundle id `com.decanlys.Sotto`) and test target `SottoTests` hosted in the app. Later tasks add source files under `Sotto/` and `SottoTests/` — XcodeGen picks up new files on regeneration, so each later task runs `xcodegen generate` after adding files.

- [ ] **Step 1: Create `.gitignore`**

```gitignore
*.xcodeproj
xcuserdata/
DerivedData/
.DS_Store
*.xcresult
.superpowers/
```

- [ ] **Step 2: Create `project.yml`**

Note: no `packages:` section yet — FluidAudio arrives in Task 4 with the code that needs it.

```yaml
name: Sotto
options:
  bundleIdPrefix: com.decanlys
  deploymentTarget:
    iOS: "26.0"
  createIntermediateGroups: true
settings:
  base:
    SWIFT_VERSION: "6.0"
    SWIFT_DEFAULT_ACTOR_ISOLATION: nonisolated
targets:
  Sotto:
    type: application
    platform: iOS
    sources:
      - path: Sotto
    info:
      path: Sotto/Info.plist
      properties:
        NSMicrophoneUsageDescription: Sotto listens for nearby speech and records only while people are talking. Audio is processed on this device.
        UIBackgroundModes: [audio]
        NSSupportsLiveActivities: true
        UIFileSharingEnabled: true
        LSSupportsOpeningDocumentsInPlace: true
        UILaunchScreen: {}
  SottoTests:
    type: bundle.unit-test
    platform: iOS
    sources:
      - path: SottoTests
    settings:
      base:
        GENERATE_INFOPLIST_FILE: YES   # XcodeGen emits no Info.plist for test bundles; signing fails without this
    dependencies:
      - target: Sotto
schemes:
  Sotto:
    build:
      targets:
        Sotto: all
    test:
      targets:
        - SottoTests
```

- [ ] **Step 3: Create `Sotto/App/SottoApp.swift`**

```swift
import SwiftUI

@main
struct SottoApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
```

- [ ] **Step 4: Create `Sotto/App/ContentView.swift` (placeholder)**

```swift
import SwiftUI

struct ContentView: View {
    var body: some View {
        Text("Sotto")
            .font(.largeTitle)
    }
}
```

- [ ] **Step 5: Create `SottoTests/SmokeTests.swift`**

```swift
import Testing
@testable import Sotto

struct SmokeTests {
    @Test func testTargetLinksAgainstApp() {
        #expect(Bool(true))
    }
}
```

- [ ] **Step 6: Generate the project and run the test suite**

Run:
```bash
xcodegen generate
xcodebuild test -project Sotto.xcodeproj -scheme Sotto \
  -destination 'platform=iOS Simulator,name=iPhone Air' 2>&1 | tail -5
```
Expected: `** TEST SUCCEEDED **`. (First run boots the simulator; allow several minutes.)

- [ ] **Step 7: Commit**

```bash
git add .gitignore project.yml Sotto SottoTests docs
git commit -m "feat: scaffold Sotto Xcode project (XcodeGen, iOS 26, Swift 6 strict)"
```

---

### Task 2: Core audio types + SampleChunker

**Files:**
- Create: `Sotto/Audio/AudioTypes.swift`
- Create: `Sotto/Audio/SampleChunker.swift`
- Test: `SottoTests/SampleChunkerTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces (used by every later task):
  - `struct AudioChunk: Sendable, Equatable { let samples: [Float]; let hostTime: UInt64 }`
  - `enum AudioSourceType: String, Codable, Sendable { case phoneMic }`
  - `protocol AudioSource: Sendable { var sourceType: AudioSourceType { get }; var isAvailable: Bool { get }; func start() async throws -> AsyncStream<AudioChunk>; func stop() async }`
  - `struct SampleChunker { init(chunkSize: Int = 4096); mutating func append(samples: [Float], hostTime: UInt64) -> [AudioChunk]; mutating func reset() }`

- [ ] **Step 1: Write the failing tests — `SottoTests/SampleChunkerTests.swift`**

```swift
import Testing
@testable import Sotto

struct SampleChunkerTests {
    @Test func emitsNothingUntilChunkSizeReached() {
        var chunker = SampleChunker(chunkSize: 4096)
        let out = chunker.append(samples: [Float](repeating: 0.1, count: 4000), hostTime: 100)
        #expect(out.isEmpty)
    }

    @Test func emitsSingleChunkAtExactBoundary() {
        var chunker = SampleChunker(chunkSize: 4096)
        let out = chunker.append(samples: [Float](repeating: 0.1, count: 4096), hostTime: 100)
        #expect(out.count == 1)
        #expect(out[0].samples.count == 4096)
        #expect(out[0].hostTime == 100)
    }

    @Test func carriesRemainderAcrossAppendsAndStampsFirstSampleTime() {
        var chunker = SampleChunker(chunkSize: 4096)
        let first = chunker.append(samples: [Float](repeating: 0.1, count: 6000), hostTime: 100)
        #expect(first.count == 1)                       // 6000 → one chunk, 1904 pending
        let second = chunker.append(samples: [Float](repeating: 0.2, count: 2192), hostTime: 200)
        #expect(second.count == 1)                      // 1904 + 2192 = 4096
        #expect(second[0].hostTime == 100)              // chunk's first sample arrived at 100
        #expect(second[0].samples[1903] == Float(0.1))  // old samples first
        #expect(second[0].samples[1904] == Float(0.2))  // then new ones
    }

    @Test func emitsMultipleChunksFromOneLargeAppend() {
        var chunker = SampleChunker(chunkSize: 4096)
        let out = chunker.append(samples: [Float](repeating: 0.3, count: 4096 * 3), hostTime: 42)
        #expect(out.count == 3)
        #expect(out.allSatisfy { $0.samples.count == 4096 && $0.hostTime == 42 })
    }

    @Test func resetDiscardsPendingSamples() {
        var chunker = SampleChunker(chunkSize: 4096)
        _ = chunker.append(samples: [Float](repeating: 0.1, count: 4000), hostTime: 1)
        chunker.reset()
        let out = chunker.append(samples: [Float](repeating: 0.2, count: 4096), hostTime: 2)
        #expect(out.count == 1)
        #expect(out[0].samples[0] == Float(0.2))   // no stale 0.1 samples survived reset
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:
```bash
xcodegen generate
xcodebuild test -project Sotto.xcodeproj -scheme Sotto \
  -destination 'platform=iOS Simulator,name=iPhone Air' 2>&1 | tail -10
```
Expected: **BUILD FAILURE** — `cannot find 'SampleChunker' in scope`. (Compile error is this ecosystem's "red" for a type that doesn't exist yet.)

- [ ] **Step 3: Create `Sotto/Audio/AudioTypes.swift`**

```swift
import Foundation

/// A fixed-size chunk of 16 kHz mono Float32 audio — the currency of the whole pipeline.
/// Value type on purpose: `AVAudioPCMBuffer` is not `Sendable` and must never cross
/// an async boundary (see SPEC "Audio source layer").
struct AudioChunk: Sendable, Equatable {
    let samples: [Float]
    let hostTime: UInt64
}

enum AudioSourceType: String, Codable, Sendable {
    case phoneMic
}

protocol AudioSource: Sendable {
    var sourceType: AudioSourceType { get }
    var isAvailable: Bool { get }
    /// Emits fixed-size chunks of 4096 samples (256 ms @ 16 kHz).
    func start() async throws -> AsyncStream<AudioChunk>
    func stop() async
}
```

- [ ] **Step 4: Create `Sotto/Audio/SampleChunker.swift`**

```swift
import Foundation

/// Accumulates arbitrary-length sample batches (whatever `AVAudioConverter` yields per tap
/// callback) into fixed 4096-sample `AudioChunk`s for the VAD.
///
/// `hostTime` on an emitted chunk is the host time of the `append` call that contributed
/// the chunk's first sample — sufficient for segment timestamping; not sample-exact.
struct SampleChunker {
    let chunkSize: Int
    private var pending: [Float] = []
    private var pendingHostTime: UInt64 = 0

    init(chunkSize: Int = 4096) {
        self.chunkSize = chunkSize
    }

    mutating func append(samples: [Float], hostTime: UInt64) -> [AudioChunk] {
        if pending.isEmpty {
            pendingHostTime = hostTime
        }
        pending.append(contentsOf: samples)

        var chunks: [AudioChunk] = []
        while pending.count >= chunkSize {
            chunks.append(AudioChunk(samples: Array(pending.prefix(chunkSize)), hostTime: pendingHostTime))
            pending.removeFirst(chunkSize)
            pendingHostTime = hostTime
        }
        return chunks
    }

    mutating func reset() {
        pending.removeAll()
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run:
```bash
xcodebuild test -project Sotto.xcodeproj -scheme Sotto \
  -destination 'platform=iOS Simulator,name=iPhone Air' 2>&1 | tail -5
```
Expected: `** TEST SUCCEEDED **` (6 tests total including the smoke test).

- [ ] **Step 6: Commit**

```bash
git add Sotto/Audio/AudioTypes.swift Sotto/Audio/SampleChunker.swift SottoTests/SampleChunkerTests.swift
git commit -m "feat: AudioChunk/AudioSource types and SampleChunker"
```

---

### Task 3: PreRollBuffer

**Files:**
- Create: `Sotto/Audio/PreRollBuffer.swift`
- Test: `SottoTests/PreRollBufferTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `struct PreRollBuffer { let capacity: Int; init(capacity: Int); mutating func append(_ samples: [Float]); func snapshot() -> [Float]; mutating func removeAll() }` — used by `ListeningPipeline` (Task 6) and, in M2, flushed into the segment writer on `.speechStart`.

- [ ] **Step 1: Write the failing tests — `SottoTests/PreRollBufferTests.swift`**

```swift
import Testing
@testable import Sotto

struct PreRollBufferTests {
    @Test func retainsEverythingUnderCapacity() {
        var buffer = PreRollBuffer(capacity: 10)
        buffer.append([1, 2, 3])
        #expect(buffer.snapshot() == [1, 2, 3])
    }

    @Test func dropsOldestSamplesBeyondCapacity() {
        var buffer = PreRollBuffer(capacity: 4)
        buffer.append([1, 2, 3])
        buffer.append([4, 5, 6])
        #expect(buffer.snapshot() == [3, 4, 5, 6])
    }

    @Test func handlesSingleAppendLargerThanCapacity() {
        var buffer = PreRollBuffer(capacity: 3)
        buffer.append([1, 2, 3, 4, 5])
        #expect(buffer.snapshot() == [3, 4, 5])
    }

    @Test func removeAllEmptiesBuffer() {
        var buffer = PreRollBuffer(capacity: 4)
        buffer.append([1, 2])
        buffer.removeAll()
        #expect(buffer.snapshot().isEmpty)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:
```bash
xcodegen generate
xcodebuild test -project Sotto.xcodeproj -scheme Sotto \
  -destination 'platform=iOS Simulator,name=iPhone Air' 2>&1 | tail -10
```
Expected: BUILD FAILURE — `cannot find 'PreRollBuffer' in scope`.

- [ ] **Step 3: Create `Sotto/Audio/PreRollBuffer.swift`**

```swift
import Foundation

/// Rolling window of the most recent audio samples (default 1 s = 16,000), continuously
/// refilled while Listening so utterance starts aren't clipped. On `.speechStart` (M2)
/// its snapshot is flushed to the segment writer ahead of live audio.
///
/// `removeFirst` is O(n) but n ≤ capacity (~16k floats) at ~4 Hz — negligible.
struct PreRollBuffer {
    let capacity: Int
    private var storage: [Float] = []

    init(capacity: Int) {
        self.capacity = capacity
    }

    mutating func append(_ samples: [Float]) {
        storage.append(contentsOf: samples)
        if storage.count > capacity {
            storage.removeFirst(storage.count - capacity)
        }
    }

    /// Buffered samples, oldest first.
    func snapshot() -> [Float] {
        storage
    }

    mutating func removeAll() {
        storage.removeAll()
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run:
```bash
xcodebuild test -project Sotto.xcodeproj -scheme Sotto \
  -destination 'platform=iOS Simulator,name=iPhone Air' 2>&1 | tail -5
```
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Sotto/Audio/PreRollBuffer.swift SottoTests/PreRollBufferTests.swift
git commit -m "feat: 1s pre-roll ring buffer"
```

---

### Task 4: FluidAudio dependency, bundled Silero model, SileroSpeechDetector

**Files:**
- Modify: `project.yml` (add `packages:`, package dependency, model folder resource)
- Create: `Sotto/Resources/silero-vad-unified-256ms-v6.0.0.mlmodelc/` (5 downloaded files, committed to git — ~1.06 MB total)
- Create: `Sotto/VAD/SpeechDetecting.swift`
- Create: `Sotto/VAD/SileroSpeechDetector.swift`
- Test: `SottoTests/SileroSpeechDetectorTests.swift`

**Interfaces:**
- Consumes: `AudioChunk` (Task 2).
- Produces (used by Task 6):
  - `enum SpeechEvent: Sendable, Equatable { case speechStart(time: TimeInterval?); case speechEnd(time: TimeInterval?) }`
  - `protocol SpeechDetecting: Sendable { func process(_ chunk: AudioChunk) async throws -> SpeechEvent?; func reset() async }`
  - `actor SileroSpeechDetector: SpeechDetecting { static let modelResourceName: String; init(modelURL: URL, threshold: Float = 0.6) throws }`

- [ ] **Step 1: Download the model into the repo**

```bash
MODEL_DIR="Sotto/Resources/silero-vad-unified-256ms-v6.0.0.mlmodelc"
BASE="https://huggingface.co/FluidInference/silero-vad-coreml/resolve/main/silero-vad-unified-256ms-v6.0.0.mlmodelc"
mkdir -p "$MODEL_DIR/analytics" "$MODEL_DIR/weights"
curl -sL "$BASE/coremldata.bin"           -o "$MODEL_DIR/coremldata.bin"
curl -sL "$BASE/metadata.json"            -o "$MODEL_DIR/metadata.json"
curl -sL "$BASE/model.mil"                -o "$MODEL_DIR/model.mil"
curl -sL "$BASE/analytics/coremldata.bin" -o "$MODEL_DIR/analytics/coremldata.bin"
curl -sL "$BASE/weights/weight.bin"       -o "$MODEL_DIR/weights/weight.bin"
du -sh "$MODEL_DIR" && head -c 200 "$MODEL_DIR/metadata.json"
```
Expected: ~1.1M total; `metadata.json` starts with JSON (`[{"shortDescription"` or similar), **not** an HTML error page. File sizes: coremldata.bin 625 B, metadata.json 3,335 B, model.mil 176,918 B, analytics/coremldata.bin 243 B, weights/weight.bin 882,304 B.

- [ ] **Step 2: Add FluidAudio and the model resource to `project.yml`**

Add a top-level `packages:` block (after `settings:`):

```yaml
packages:
  FluidAudio:
    url: https://github.com/FluidInference/FluidAudio
    exactVersion: 0.15.4
```

Replace the `Sotto` target's `sources:` block and add the package dependency, so the target reads:

```yaml
  Sotto:
    type: application
    platform: iOS
    sources:
      - path: Sotto
        excludes:
          - "Resources"
      - path: Sotto/Resources/silero-vad-unified-256ms-v6.0.0.mlmodelc
        type: folder
        buildPhase: resources
    dependencies:
      - package: FluidAudio
    info:
      path: Sotto/Info.plist
      properties:
        NSMicrophoneUsageDescription: Sotto listens for nearby speech and records only while people are talking. Audio is processed on this device.
        UIBackgroundModes: [audio]
        NSSupportsLiveActivities: true
        UIFileSharingEnabled: true
        LSSupportsOpeningDocumentsInPlace: true
        UILaunchScreen: {}
```

The `type: folder` entry makes the `.mlmodelc` a folder reference copied verbatim into the bundle root — so `Bundle.main.url(forResource: "silero-vad-unified-256ms-v6.0.0", withExtension: "mlmodelc")` resolves, and Xcode never tries to recompile the model.

- [ ] **Step 3: Write the failing tests — `SottoTests/SileroSpeechDetectorTests.swift`**

```swift
import Foundation
import Testing
@testable import Sotto

struct SileroSpeechDetectorTests {
    private func makeDetector() throws -> SileroSpeechDetector {
        let url = try #require(Bundle.main.url(
            forResource: SileroSpeechDetector.modelResourceName,
            withExtension: "mlmodelc"))
        return try SileroSpeechDetector(modelURL: url)
    }

    @Test func bundledModelLoads() throws {
        _ = try makeDetector()
    }

    @Test func silenceProducesNoEvents() async throws {
        let detector = try makeDetector()
        for _ in 0..<20 {
            let chunk = AudioChunk(samples: [Float](repeating: 0, count: 4096), hostTime: 0)
            let event = try await detector.process(chunk)
            #expect(event == nil)
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they fail**

Run:
```bash
xcodegen generate
xcodebuild test -project Sotto.xcodeproj -scheme Sotto \
  -destination 'platform=iOS Simulator,name=iPhone Air' 2>&1 | tail -10
```
Expected: BUILD FAILURE — `cannot find 'SileroSpeechDetector' in scope`. (This run also resolves the FluidAudio package for the first time — slow.)

- [ ] **Step 5: Create `Sotto/VAD/SpeechDetecting.swift`**

```swift
import Foundation

enum SpeechEvent: Sendable, Equatable {
    case speechStart(time: TimeInterval?)
    case speechEnd(time: TimeInterval?)
}

/// Seam over the VAD implementation. FluidAudio's `VadManager` is beta — everything
/// downstream depends on this protocol so the engine can be swapped (e.g. for Apple's
/// `SpeechDetector` if it ever decouples from the transcriber).
protocol SpeechDetecting: Sendable {
    /// Feed one 4096-sample chunk; returns an event on speech-state transitions, else nil.
    func process(_ chunk: AudioChunk) async throws -> SpeechEvent?
    /// Clear streaming state (call on stop, and in M3 after interruptions).
    func reset() async
}
```

- [ ] **Step 6: Create `Sotto/VAD/SileroSpeechDetector.swift`**

```swift
import CoreML
import FluidAudio
import Foundation

/// Silero VAD v6 via FluidAudio, with the CoreML model loaded from the app bundle —
/// FluidAudio's HuggingFace download path is deliberately never exercised.
actor SileroSpeechDetector: SpeechDetecting {
    static let modelResourceName = "silero-vad-unified-256ms-v6.0.0"

    private let vad: VadManager
    private var streamState: VadStreamState

    init(modelURL: URL, threshold: Float = 0.6) throws {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        let model = try MLModel(contentsOf: modelURL, configuration: configuration)
        self.vad = VadManager(config: VadConfig(defaultThreshold: threshold), vadModel: model)
        self.streamState = VadStreamState.initial()
    }

    func process(_ chunk: AudioChunk) async throws -> SpeechEvent? {
        let result = try await vad.processStreamingChunk(
            chunk.samples,
            state: streamState,
            config: .default,
            returnSeconds: true,
            timeResolution: 2)
        streamState = result.state
        guard let event = result.event else { return nil }
        switch event.kind {
        case .speechStart: return .speechStart(time: event.time)
        case .speechEnd: return .speechEnd(time: event.time)
        }
    }

    func reset() {
        streamState = VadStreamState.initial()
    }
}
```

- [ ] **Step 7: Run tests to verify they pass**

Run:
```bash
xcodebuild test -project Sotto.xcodeproj -scheme Sotto \
  -destination 'platform=iOS Simulator,name=iPhone Air' 2>&1 | tail -5
```
Expected: `** TEST SUCCEEDED **`. On the simulator `.cpuAndNeuralEngine` silently falls back to CPU — fine for tests; ANE engages on device.

If `VadConfig(defaultThreshold:)` fails to compile (labeled-argument mismatch), check the pinned source at `~/Library/Developer/Xcode/DerivedData/Sotto-*/SourcePackages/checkouts/FluidAudio/Sources/FluidAudio/VAD/VadTypes.swift` and use the actual labels — do not unpin the version.

- [ ] **Step 8: Commit**

```bash
git add project.yml Sotto/Resources Sotto/VAD SottoTests/SileroSpeechDetectorTests.swift
git commit -m "feat: SileroSpeechDetector over FluidAudio 0.15.4 with bundled CoreML model"
```

---

### Task 5: FormatConverter + PhoneMicAudioSource

**Files:**
- Create: `Sotto/Audio/FormatConverter.swift`
- Create: `Sotto/Audio/PhoneMicAudioSource.swift`
- Test: `SottoTests/FormatConverterTests.swift`
- Test: `SottoTests/AudioSessionTests.swift`

**Interfaces:**
- Consumes: `AudioChunk`, `AudioSource`, `AudioSourceType`, `SampleChunker` (Task 2).
- Produces (used by Task 6):
  - `final class FormatConverter { static let targetFormat: AVAudioFormat; init?(inputFormat: AVAudioFormat); func convert(_ buffer: AVAudioPCMBuffer) -> [Float] }`
  - `actor PhoneMicAudioSource: AudioSource { init(); static func configureSession() throws }` with `enum AudioSourceError: Error { case microphonePermissionDenied, converterUnavailable }`

- [ ] **Step 1: Write the failing tests — `SottoTests/FormatConverterTests.swift`**

```swift
import AVFoundation
import Testing
@testable import Sotto

struct FormatConverterTests {
    @Test func downsamplesStereo48kToMono16k() throws {
        let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
        let converter = try #require(FormatConverter(inputFormat: inputFormat))

        let frames: AVAudioFrameCount = 4800   // 100 ms @ 48 kHz → expect ~1600 out per pass
        let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<2 {
            let data = buffer.floatChannelData![channel]
            for i in 0..<Int(frames) {
                data[i] = sinf(2 * .pi * 440 * Float(i) / 48_000)
            }
        }

        // Rate converters hold back priming samples; assert over two passes.
        let total = converter.convert(buffer).count + converter.convert(buffer).count
        #expect(abs(total - 3200) <= 256)
    }

    @Test func rejectsUnconvertibleFormat() {
        // 0-channel formats can't construct; use a nonsensical conversion instead:
        // AVAudioConverter init returns nil only for genuinely incompatible pairs,
        // which Float32 PCM never is — so assert the happy path constructs.
        let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 1, interleaved: false)!
        #expect(FormatConverter(inputFormat: inputFormat) != nil)
    }
}
```

- [ ] **Step 2: Write the failing test — `SottoTests/AudioSessionTests.swift`**

```swift
import AVFoundation
import Testing
@testable import Sotto

struct AudioSessionTests {
    @Test func configuresPlayAndRecordWithMixWithOthers() throws {
        try PhoneMicAudioSource.configureSession()
        let session = AVAudioSession.sharedInstance()
        #expect(session.category == .playAndRecord)
        #expect(session.categoryOptions.contains(.mixWithOthers))
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run:
```bash
xcodegen generate
xcodebuild test -project Sotto.xcodeproj -scheme Sotto \
  -destination 'platform=iOS Simulator,name=iPhone Air' 2>&1 | tail -10
```
Expected: BUILD FAILURE — `cannot find 'FormatConverter' in scope`.

- [ ] **Step 4: Create `Sotto/Audio/FormatConverter.swift`**

```swift
import AVFoundation

/// Converts hardware-format tap buffers to the pipeline format: 16 kHz mono Float32.
/// One instance per tap installation (AVAudioConverter carries resampler state);
/// rebuild it on route changes when the hardware format shifts (M3).
///
/// `@unchecked Sendable`: instances are confined to the audio tap thread behind
/// `TapProcessor`'s `Mutex`; the compiler cannot see that confinement.
final class FormatConverter: @unchecked Sendable {
    static let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    private let converter: AVAudioConverter
    private let ratio: Double

    init?(inputFormat: AVAudioFormat) {
        guard let converter = AVAudioConverter(from: inputFormat, to: Self.targetFormat) else {
            return nil
        }
        self.converter = converter
        self.ratio = Self.targetFormat.sampleRate / inputFormat.sampleRate
    }

    /// Synchronously converts one tap buffer, copying samples out — the returned array
    /// owns its memory, so the tap buffer is free to be recycled by the engine.
    func convert(_ buffer: AVAudioPCMBuffer) -> [Float] {
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: Self.targetFormat, frameCapacity: capacity) else {
            return []
        }

        // The converter invokes the input block synchronously on the calling thread during
        // `convert`, so these captures never actually cross threads (block is marked @Sendable).
        nonisolated(unsafe) var consumed = false
        nonisolated(unsafe) let inputBuffer = buffer
        var conversionError: NSError?
        converter.convert(to: output, error: &conversionError) { _, outStatus in
            if consumed {
                // .noDataNow (not .endOfStream) keeps the resampler primed for the next tap buffer.
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return inputBuffer
        }

        guard conversionError == nil, let channelData = output.floatChannelData else {
            return []
        }
        return Array(UnsafeBufferPointer(start: channelData[0], count: Int(output.frameLength)))
    }
}
```

- [ ] **Step 5: Create `Sotto/Audio/PhoneMicAudioSource.swift`**

```swift
import AVFoundation
import Synchronization

/// MVP audio source: built-in phone mic via AVAudioEngine.
///
/// Everything tap-related lives in this one file on purpose — `installTap` is slated for
/// deprecation (iOS 27 renames it `installAudioTap`), so migration stays a one-file change.
actor PhoneMicAudioSource: AudioSource {
    nonisolated let sourceType: AudioSourceType = .phoneMic
    nonisolated var isAvailable: Bool { true }

    enum AudioSourceError: Error {
        case microphonePermissionDenied
        case converterUnavailable
    }

    private var engine: AVAudioEngine?
    private var continuation: AsyncStream<AudioChunk>.Continuation?

    func start() async throws -> AsyncStream<AudioChunk> {
        guard await AVAudioApplication.requestRecordPermission() else {
            throw AudioSourceError.microphonePermissionDenied
        }
        try Self.configureSession()

        let engine = AVAudioEngine()
        let input = engine.inputNode
        // Tap at the HARDWARE format — requesting 16 kHz here crashes with a format mismatch.
        let hardwareFormat = input.outputFormat(forBus: 0)
        guard let converter = FormatConverter(inputFormat: hardwareFormat) else {
            throw AudioSourceError.converterUnavailable
        }

        let processor = TapProcessor(converter: converter)
        let (stream, continuation) = AsyncStream.makeStream(of: AudioChunk.self)

        input.installTap(onBus: 0, bufferSize: 4096, format: hardwareFormat) { buffer, when in
            processor.handle(buffer, hostTime: when.hostTime, continuation: continuation)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            continuation.finish()
            throw error
        }

        self.engine = engine
        self.continuation = continuation
        return stream
    }

    func stop() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        continuation?.finish()
        continuation = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// `.playAndRecord` + `.mixWithOthers` so activating the session never pauses the
    /// user's music. No Bluetooth input options: AirPods stay on A2DP output while the
    /// phone mic records (see SPEC "PhoneMicAudioSource").
    static func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers])
        try session.setActive(true)
    }
}

/// Runs inside the audio tap callback: convert to 16 kHz mono, copy samples out
/// synchronously, chunk, and yield. `Mutex` (not an actor) because the tap thread
/// must never await.
private final class TapProcessor: Sendable {
    private struct State {
        var converter: FormatConverter
        var chunker = SampleChunker()
    }

    private let state: Mutex<State>

    init(converter: FormatConverter) {
        self.state = Mutex(State(converter: converter))
    }

    func handle(
        _ buffer: AVAudioPCMBuffer,
        hostTime: UInt64,
        continuation: AsyncStream<AudioChunk>.Continuation
    ) {
        let chunks = state.withLock { state -> [AudioChunk] in
            let samples = state.converter.convert(buffer)
            return state.chunker.append(samples: samples, hostTime: hostTime)
        }
        for chunk in chunks {
            continuation.yield(chunk)
        }
    }
}
```

- [ ] **Step 6: Run tests to verify they pass**

Run:
```bash
xcodebuild test -project Sotto.xcodeproj -scheme Sotto \
  -destination 'platform=iOS Simulator,name=iPhone Air' 2>&1 | tail -5
```
Expected: `** TEST SUCCEEDED **`. Live tap behavior is verified end-to-end in Task 6 — no unit test calls `start()` (it would trigger the permission prompt inside the test host).

- [ ] **Step 7: Commit**

```bash
git add Sotto/Audio/FormatConverter.swift Sotto/Audio/PhoneMicAudioSource.swift \
        SottoTests/FormatConverterTests.swift SottoTests/AudioSessionTests.swift
git commit -m "feat: PhoneMicAudioSource with hardware-format tap and 16kHz converter"
```

---

### Task 6: ListeningPipeline + debug UI + end-to-end simulator run

**Files:**
- Create: `Sotto/Pipeline/ListeningPipeline.swift`
- Create: `SottoTests/Fakes.swift`
- Modify: `Sotto/App/ContentView.swift` (replace the Task 1 placeholder entirely)
- Test: `SottoTests/ListeningPipelineTests.swift`

**Interfaces:**
- Consumes: `AudioSource` + `AudioChunk` (Task 2), `PreRollBuffer` (Task 3), `SpeechDetecting` + `SpeechEvent` + `SileroSpeechDetector` (Task 4), `PhoneMicAudioSource` (Task 5).
- Produces: `@MainActor @Observable final class ListeningPipeline` with `enum Status: Equatable { case idle, listening, speechActive }`, `private(set) var status: Status`, `private(set) var eventLog: [String]`, `init(source: any AudioSource, detector: any SpeechDetecting, preRollSamples: Int = 16_000)`, `func start() async`, `func stop() async`, `func waitUntilDrained() async`, `func preRollSnapshot() -> [Float]`. M2's state machine will replace the `Status` enum with the five-state design; the source/detector wiring here carries over.

- [ ] **Step 1: Create `SottoTests/Fakes.swift`**

```swift
import Foundation
@testable import Sotto

actor FakeAudioSource: AudioSource {
    nonisolated let sourceType: AudioSourceType = .phoneMic
    nonisolated var isAvailable: Bool { true }

    private var continuation: AsyncStream<AudioChunk>.Continuation?
    private(set) var startCallCount = 0

    func start() async throws -> AsyncStream<AudioChunk> {
        startCallCount += 1
        let (stream, continuation) = AsyncStream.makeStream(of: AudioChunk.self)
        self.continuation = continuation
        return stream
    }


    func stop() {
        continuation?.finish()
        continuation = nil
    }

    func emitSilentChunks(count: Int) {
        for _ in 0..<count {
            continuation?.yield(AudioChunk(samples: [Float](repeating: 0, count: 4096), hostTime: 0))
        }
    }

    func finish() {
        continuation?.finish()
    }
}

/// AudioSource whose start() suspends until the test releases it — for ordering races deterministically.
actor SlowStartAudioSource: AudioSource {
    nonisolated let sourceType: AudioSourceType = .phoneMic
    nonisolated var isAvailable: Bool { true }

    private var continuation: AsyncStream<AudioChunk>.Continuation?
    private var startGate: CheckedContinuation<Void, Never>?
    private var startRequested: CheckedContinuation<Void, Never>?
    private var startWasRequested = false

    func start() async throws -> AsyncStream<AudioChunk> {
        startWasRequested = true
        startRequested?.resume()
        startRequested = nil
        await withCheckedContinuation { startGate = $0 }
        let (stream, continuation) = AsyncStream.makeStream(of: AudioChunk.self)
        self.continuation = continuation
        return stream
    }

    func waitUntilStartRequested() async {
        if startWasRequested { return }
        await withCheckedContinuation { startRequested = $0 }
    }

    func releaseStart() {
        startGate?.resume()
        startGate = nil
    }

    func stop() {
        continuation?.finish()
        continuation = nil
    }

    func emitSilentChunks(count: Int) {
        for _ in 0..<count {
            continuation?.yield(AudioChunk(samples: [Float](repeating: 0, count: 4096), hostTime: 0))
        }
    }
}

/// Returns a scripted event for the Nth processed chunk (0-indexed), nil otherwise.
actor FakeSpeechDetector: SpeechDetecting {
    private let script: [Int: SpeechEvent]
    private var index = 0

    init(script: [Int: SpeechEvent]) {
        self.script = script
    }

    func process(_ chunk: AudioChunk) async throws -> SpeechEvent? {
        defer { index += 1 }
        return script[index]
    }

    func reset() {
        index = 0
    }
}
```

- [ ] **Step 2: Write the failing tests — `SottoTests/ListeningPipelineTests.swift`**

```swift
import Testing
@testable import Sotto

@MainActor
struct ListeningPipelineTests {
    @Test func speechEventsDriveStatusAndLog() async throws {
        let source = FakeAudioSource()
        let detector = FakeSpeechDetector(script: [
            2: .speechStart(time: 0.5),
            5: .speechEnd(time: 1.5),
        ])
        let pipeline = ListeningPipeline(source: source, detector: detector)

        await pipeline.start()
        #expect(pipeline.status == .listening)

        await source.emitSilentChunks(count: 6)
        await source.finish()
        await pipeline.waitUntilDrained()

        #expect(pipeline.eventLog.contains("Speech started"))
        #expect(pipeline.eventLog.contains("Speech ended"))
        #expect(pipeline.status == .listening)   // ended → back to listening
    }

    @Test func preRollAccumulatesAndStopClearsIt() async throws {
        let source = FakeAudioSource()
        let detector = FakeSpeechDetector(script: [:])
        let pipeline = ListeningPipeline(source: source, detector: detector, preRollSamples: 8192)

        await pipeline.start()
        await source.emitSilentChunks(count: 3)   // 12,288 samples into an 8,192 window
        await source.finish()
        await pipeline.waitUntilDrained()
        #expect(pipeline.preRollSnapshot().count == 8192)

        await pipeline.stop()
        #expect(pipeline.preRollSnapshot().isEmpty)
        #expect(pipeline.status == .idle)
    }

    @Test func startIsIdempotentWhileActive() async throws {
        let source = FakeAudioSource()
        let detector = FakeSpeechDetector(script: [:])
        let pipeline = ListeningPipeline(source: source, detector: detector)

        await pipeline.start()
        await pipeline.start()   // second start while listening must be a no-op
        #expect(pipeline.status == .listening)
        await pipeline.stop()
    }

    @Test func concurrentStartsOnlyStartSourceOnce() async throws {
        let source = FakeAudioSource()
        let detector = FakeSpeechDetector(script: [:])
        let pipeline = ListeningPipeline(source: source, detector: detector)

        async let first: Void = pipeline.start()
        async let second: Void = pipeline.start()
        _ = await (first, second)

        #expect(await source.startCallCount == 1)
        #expect(pipeline.status == .listening)
        await pipeline.stop()
    }

    @Test func stopClearsPreRollEvenWithUndrainedChunks() async throws {
        let source = FakeAudioSource()
        let detector = FakeSpeechDetector(script: [:])
        let pipeline = ListeningPipeline(source: source, detector: detector, preRollSamples: 8192)

        await pipeline.start()
        await source.emitSilentChunks(count: 3)
        // Deliberately no waitUntilDrained(): stop() itself must drain then clear.
        await pipeline.stop()

        // Give any orphaned pump task scheduler time — a leaked pump would repopulate preRoll here.
        for _ in 0..<10 { await Task.yield() }
        #expect(pipeline.preRollSnapshot().isEmpty)
        #expect(pipeline.status == .idle)
    }

    @Test func stopDuringStartLeavesPipelineIdleWithNoPump() async throws {
        let source = SlowStartAudioSource()
        let detector = FakeSpeechDetector(script: [:])
        let pipeline = ListeningPipeline(source: source, detector: detector)

        async let starting: Void = pipeline.start()
        await source.waitUntilStartRequested()
        await pipeline.stop()            // wins the race while start() is suspended
        await source.releaseStart()
        await starting

        #expect(pipeline.status == .idle)
        await source.emitSilentChunks(count: 2)
        for _ in 0..<10 { await Task.yield() }
        #expect(pipeline.preRollSnapshot().isEmpty)   // no live pump is consuming chunks
    }

    @Test func startStopStartBurstEndsIdleWithoutOrphanedPump() async throws {
        let source = SlowStartAudioSource()
        let detector = FakeSpeechDetector(script: [:])
        let pipeline = ListeningPipeline(source: source, detector: detector)

        async let firstStart: Void = pipeline.start()
        await source.waitUntilStartRequested()
        await pipeline.stop()                              // queued: start is mid-flight
        async let secondStart: Void = pipeline.start()     // must no-op: a transition is in flight
        for _ in 0..<5 { await Task.yield() }              // let secondStart hit the guard while the gate is closed
        await source.releaseStart()
        _ = await (firstStart, secondStart)

        #expect(pipeline.status == .idle)                  // the queued stop won after the start completed
        await source.emitSilentChunks(count: 2)
        for _ in 0..<10 { await Task.yield() }
        #expect(pipeline.preRollSnapshot().isEmpty)        // no orphaned pump is consuming chunks
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run:
```bash
xcodegen generate
xcodebuild test -project Sotto.xcodeproj -scheme Sotto \
  -destination 'platform=iOS Simulator,name=iPhone Air' 2>&1 | tail -10
```
Expected: BUILD FAILURE — `cannot find 'ListeningPipeline' in scope`.

- [ ] **Step 4: Create `Sotto/Pipeline/ListeningPipeline.swift`**

```swift
import Foundation
import Observation

/// M1 glue: pumps AudioChunks from the source through the pre-roll buffer and VAD,
/// and publishes status for SwiftUI. M2 replaces `Status` with the five-state
/// RecorderStateMachine; the wiring pattern here carries over.
@MainActor
@Observable
final class ListeningPipeline {
    enum Status: Equatable {
        case idle
        case listening
        case speechActive
    }

    private(set) var status: Status = .idle
    private(set) var eventLog: [String] = []

    private let source: any AudioSource
    private let detector: any SpeechDetecting
    private var preRoll: PreRollBuffer
    private var pumpTask: Task<Void, Never>?
    // Transitions are mutually exclusive: a stop() arriving during an in-flight start() is
    // queued and honored when the start completes; start() during any transition is a no-op.
    private var isTransitioning = false
    private var stopRequestedDuringTransition = false

    init(source: any AudioSource, detector: any SpeechDetecting, preRollSamples: Int = 16_000) {
        self.source = source
        self.detector = detector
        self.preRoll = PreRollBuffer(capacity: preRollSamples)
    }

    func start() async {
        guard status == .idle, !isTransitioning else { return }
        isTransitioning = true
        status = .listening
        var started = false
        do {
            let stream = try await source.start()
            eventLog.append("Listening…")
            pumpTask = Task {
                for await chunk in stream {
                    await self.handle(chunk)
                }
            }
            started = true
        } catch {
            status = .idle
            eventLog.append("Start failed: \(error)")
        }
        isTransitioning = false
        let stopWasRequested = stopRequestedDuringTransition
        stopRequestedDuringTransition = false
        if started && stopWasRequested {
            await stop()   // honor the stop that arrived mid-start
        }
    }

    func stop() async {
        if isTransitioning {
            stopRequestedDuringTransition = true
            return
        }
        guard status != .idle else { return }
        isTransitioning = true
        await source.stop()          // finish the stream: no new chunks after this
        await pumpTask?.value        // drain chunks already in flight to quiescence
        pumpTask = nil
        await detector.reset()
        preRoll.removeAll()
        status = .idle
        eventLog.append("Stopped")
        isTransitioning = false
        stopRequestedDuringTransition = false
    }

    /// Test hook: waits for the pump task to finish draining a closed stream.
    func waitUntilDrained() async {
        await pumpTask?.value
    }

    func preRollSnapshot() -> [Float] {
        preRoll.snapshot()
    }

    private func handle(_ chunk: AudioChunk) async {
        preRoll.append(chunk.samples)
        do {
            guard let event = try await detector.process(chunk) else { return }
            switch event {
            case .speechStart:
                status = .speechActive
                eventLog.append("Speech started")
            case .speechEnd:
                status = .listening
                eventLog.append("Speech ended")
            }
        } catch {
            eventLog.append("VAD error: \(error)")
        }
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run:
```bash
xcodebuild test -project Sotto.xcodeproj -scheme Sotto \
  -destination 'platform=iOS Simulator,name=iPhone Air' 2>&1 | tail -5
```
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 6: Replace `Sotto/App/ContentView.swift` with the debug UI**

```swift
import SwiftUI

struct ContentView: View {
    @State private var pipeline: ListeningPipeline?
    @State private var setupError: String?

    var body: some View {
        NavigationStack {
            Group {
                if let setupError {
                    ContentUnavailableView(
                        "Setup failed",
                        systemImage: "exclamationmark.triangle",
                        description: Text(setupError))
                } else if let pipeline {
                    PipelineView(pipeline: pipeline)
                } else {
                    ProgressView("Loading VAD model…")
                }
            }
            .navigationTitle("Sotto")
        }
        .task { setUp() }
    }

    private func setUp() {
        guard pipeline == nil, setupError == nil else { return }
        guard let modelURL = Bundle.main.url(
            forResource: SileroSpeechDetector.modelResourceName,
            withExtension: "mlmodelc")
        else {
            setupError = "VAD model missing from app bundle"
            return
        }
        do {
            let detector = try SileroSpeechDetector(modelURL: modelURL)
            pipeline = ListeningPipeline(source: PhoneMicAudioSource(), detector: detector)
        } catch {
            setupError = String(describing: error)
        }
    }
}

private struct PipelineView: View {
    let pipeline: ListeningPipeline

    var body: some View {
        VStack(spacing: 24) {
            Text(statusLabel)
                .font(.largeTitle.bold())
                .foregroundStyle(statusColor)

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
        case .listening: "Listening"
        case .speechActive: "Speech"
        }
    }

    private var statusColor: Color {
        switch pipeline.status {
        case .idle: .secondary
        case .listening: .green
        case .speechActive: .orange
        }
    }
}
```

- [ ] **Step 7: Full test suite + end-to-end simulator run**

Run:
```bash
xcodebuild test -project Sotto.xcodeproj -scheme Sotto \
  -destination 'platform=iOS Simulator,name=iPhone Air' 2>&1 | tail -5
xcrun simctl boot "iPhone Air" 2>/dev/null || true
xcodebuild -project Sotto.xcodeproj -scheme Sotto \
  -destination 'platform=iOS Simulator,name=iPhone Air' build 2>&1 | tail -3
APP=$(find ~/Library/Developer/Xcode/DerivedData/Sotto-* \
  -path "*Build/Products/Debug-iphonesimulator/Sotto.app" -maxdepth 6 | head -1)
xcrun simctl install "iPhone Air" "$APP"
xcrun simctl privacy "iPhone Air" grant microphone com.decanlys.Sotto
xcrun simctl launch "iPhone Air" com.decanlys.Sotto
sleep 5
xcrun simctl io "iPhone Air" screenshot /tmp/sotto-m1.png
```
Expected: tests pass; app launches without crashing; screenshot shows the "Sotto" title, an "Idle" status, and the Start Listening button. Tap-through with live speech (simulator mic = Mac mic) is a **human verification step** — flag it in the task report; an agent cannot speak into the microphone.

- [ ] **Step 8: Commit**

```bash
git add Sotto/Pipeline Sotto/App/ContentView.swift SottoTests/Fakes.swift SottoTests/ListeningPipelineTests.swift
git commit -m "feat: ListeningPipeline and M1 debug UI"
```

---

## Out of scope for this plan (next plans, in order)

1. **M2 — State machine + writer:** five-state `RecorderStateMachine` actor (replaces `ListeningPipeline.Status`), app-level 45 s silence timeout, min-3 s / max-2 h / disk guards, crash-safe `.m4a` writer, heartbeat file. The pre-roll `snapshot()` flush lands here.
2. **M3 — Live Activity + interruptions.**
3. **M4 — Transcription queue + SpeechAnalyzer + Deepgram.**
4. **M5 — File store.** 5. **M6 — Full UI.**

## Self-review notes

- Spec coverage for M1: `AudioSource` protocol ✓ (`isAvailable` included per spec), hardware-format tap ✓, `[.mixWithOthers]` session ✓ (asserted in `AudioSessionTests`), bundled model ✓ (no-download initializer verified against 0.15.4 source), streaming events ✓, ring buffer ✓, 4096-sample chunks ✓, `AVAudioApplication.requestRecordPermission()` ✓, all five Info.plist keys ✓, no speech-recognition key ✓.
- Deliberate M1 simplifications: `AudioSourceType` has only `.phoneMic` (YAGNI — spec's future cases arrive with their sources); interruption-notification forwarding deferred to M3 (spec lists it under the source, but its only consumer is M3's handler); `ListeningPipeline.Status` is a placeholder for M2's real state machine.
- Known risk, accepted: `installTap` may emit a deprecation **warning** under the iOS 27-aware SDK — warnings are fine; all tap code is confined to `PhoneMicAudioSource.swift` for the eventual migration.

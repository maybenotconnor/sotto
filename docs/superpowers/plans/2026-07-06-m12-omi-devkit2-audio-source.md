# M12 — Omi Devkit 2 Audio Source Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Support the Omi Devkit 2 BLE wearable as an audio source: when paired, Sotto streams Opus audio from the pendant, decodes it to the pipeline's 16 kHz mono chunks, and automatically falls back to the phone mic (and back) on disconnect — with pairing UI, battery surfacing, and per-conversation source labeling.

**Architecture:** A new `Sotto/Omi/` layer turns BLE notifications into `AudioChunk`s (`OmiTransport` → `OmiFrameAssembler` → `OmiAudioDecoder` → reused `SampleChunker`), wrapped by `OmiAudioSource: AudioSource`. A `FailoverAudioSource: AudioSource` composes the Omi source with `PhoneMicAudioSource` and swaps between them (3 s grace out, 10 s hysteresis back), emitting source-change events the pipeline turns into segment rollovers. Everything downstream of `AudioSource` is unchanged except an additive `source` label threaded through segment → job → frontmatter → day index. Spec: `docs/superpowers/specs/2026-07-06-omi-devkit2-audio-source-design.md`.

**Tech Stack:** Swift 6 strict concurrency, actors, AsyncStream, CoreBluetooth, swift-opus (nelcea, 1.0.0), Swift Testing (`@Test`), XcodeGen.

## Global Constraints

- Test command: `xcodebuild test -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone Air' 2>&1 | tail -5` → must end `** TEST SUCCEEDED **`. Scope iteration with `-only-testing:SottoTests/<SuiteName>` while developing; run the full suite before each commit.
- After creating/deleting ANY file: `xcodegen generate` (project.yml is the source of truth; never edit the .xcodeproj or Info.plist by hand).
- Swift 6, `SWIFT_DEFAULT_ACTOR_ISOLATION: nonisolated`, zero new warnings.
- The `AudioSource.stop()` contract (`Sotto/Audio/AudioTypes.swift:20-26`) is BINDING for both new sources: stop() must finish the stream continuation on every path, be idempotent, and be safe when never started.
- Existing behavior that must NOT change: phone-mic-only users (no paired Omi) get byte-identical behavior; existing markdown output stays byte-identical for phone-mic segments (the `source:` frontmatter line is written ONLY for `.omi`); all existing tests keep passing with at most additive default-parameter changes.
- BLE protocol constants (from BasedHardware/omi, MIT): audio service `19B10000-E8F2-537E-4F6C-D104768A1214`, audio data notify `19B10001-…`, codec read `19B10002-…`; battery service `180F` / level `2A19`; packet framing `[uint16 LE packet# | uint8 fragment idx | payload]`, packet# wraps 0xFFFF→0; codec values: 0=PCM16/16k, 1=PCM16/8k, 10=µ-law/16k, 11=µ-law/8k, 20=Opus/16k (firmware ≥1.0.3 default).
- Scope decisions (spec): 8 kHz codec values (1, 11) are REJECTED as unsupported (surfaced in Settings); dropped packets are filled with silence (320 zero samples per missing packet) — true Opus PLC is a post-hardware-verification polish item; salvaged CAFs are labeled `.phoneMic` (source is unknowable after a crash — documented limitation).
- Commits end with:

  Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>

## File Structure

```
project.yml                                    ← swift-opus package, bluetooth-central, NSBluetoothAlwaysUsageDescription (modify)
Sotto/Omi/Vendored/OmiCodecs.swift             ← vendored from omi-lib Codecs.swift, MIT header (new)
Sotto/Omi/OmiConstants.swift                   ← UUIDs, codec table, framing/threshold constants (new)
Sotto/Omi/OmiFrameAssembler.swift              ← notification bytes → frames + gap signals (new)
Sotto/Omi/OmiAudioDecoder.swift                ← codec value → [Float] 16 kHz mono, silence fill (new)
Sotto/Omi/OmiTransport.swift                   ← transport protocol + events + discovery types (new)
Sotto/Omi/OmiAudioSource.swift                 ← AudioSource actor over transport (new)
Sotto/Omi/FailoverAudioSource.swift            ← Omi↔phone-mic supervisor (new)
Sotto/Omi/CoreBluetoothOmiTransport.swift      ← real CBCentralManager transport (new)
Sotto/Omi/OmiDeviceStore.swift                 ← paired-device persistence (new)
Sotto/Audio/AudioTypes.swift                   ← AudioSourceType.omi + displayName (modify)
Sotto/Segments/SegmentWriting.swift            ← FinalizedSegment.source (modify)
Sotto/Recorder/RecorderStateMachine.swift      ← activeSource + rollover(to:) (modify)
Sotto/Recorder/RecorderTypes.swift             ← SegmentRecording protocol additions (modify)
Sotto/Pipeline/ListeningPipeline.swift         ← source-change handling, activeSourceType (modify)
Sotto/Transcription/TranscriptionQueue.swift   ← TranscriptionJob.source (modify)
Sotto/Transcription/TranscriptMarkdownWriter.swift ← source: frontmatter (modify)
Sotto/Files/DayIndex.swift                     ← DaySegmentEntry.source (modify)
Sotto/Files/DayIndexStore.swift                ← recordQueuedSegment(source:) (modify)
Sotto/Files/DayIndexRebuilder.swift            ← parse source frontmatter (modify)
Sotto/Notifications/…(NotificationScheduling)  ← 3 new notification methods (modify)
Sotto/LiveActivity/SottoActivityAttributes.swift ← ContentState.sourceLabel (modify)
Sotto/LiveActivity/LiveActivityControlling.swift ← update(… sourceLabel:) (modify)
SottoWidgets/…                                 ← render sourceLabel (modify)
Sotto/App/AppModel.swift                       ← composition branch, pairing, battery, rebuild (modify)
Sotto/App/SettingsView.swift                   ← Omi Device section (modify)
Sotto/App/OmiPairSheet.swift                   ← scan/pair sheet (new)
Sotto/App/ContentView.swift                    ← home header source label (modify)
docs/SPEC.md                                   ← audio source layer update (modify)
docs/superpowers/plans/2026-07-06-m12-hardware-verification.md ← user-owned checklist (new)
SottoTests/Omi*.swift, Fakes.swift, existing suites (new/modify)
```

**Task order:** 1 → 2 → 3 → 4 → 5 → 6 → 7 → 8 → 9 → 10 → 11 → 12 → 13. Tasks 3 and 4 are independent of 2. Task 9 (real CoreBluetooth) has no automated tests — everything it feeds is tested through fakes in 5–8.

---

### Task 1: Project configuration + vendored decode files

Add the swift-opus dependency, BLE Info.plist keys, and the two vendored MIT files. Deliverable: project builds with `import Opus` available in app and test targets; µ-law/PCM vendored codecs unit-tested.

**Files:**
- Modify: `project.yml`
- Create: `Sotto/Omi/Vendored/OmiCodecs.swift`
- Test: `SottoTests/OmiVendoredCodecTests.swift`

**Interfaces:**
- Produces: `OmiCodec` protocol (`sampleRate`, `init(sampleRate:) throws`, `decode(data: Data) throws -> Data`), `OmiPcmCodec`, `OmiMuLawCodec`, `OmiOpusCodec`, `OmiCodecError` — consumed by Task 4's `OmiAudioDecoder`.

- [ ] **Step 1: Update project.yml**

Apply these edits (context lines shown; keep everything else):

```yaml
packages:
  FluidAudio:
    url: https://github.com/FluidInference/FluidAudio
    exactVersion: 0.15.4
  SwiftOpus:
    url: https://github.com/nelcea/swift-opus
    exactVersion: 1.0.0
```

Sotto target dependencies:

```yaml
    dependencies:
      - package: FluidAudio
      - package: SwiftOpus
        product: Opus
      - target: SottoWidgets
        embed: true
```

Sotto target info.properties — add the Bluetooth usage string and extend background modes:

```yaml
        NSBluetoothAlwaysUsageDescription: Sotto connects to your paired Omi wearable to capture audio from its microphone.
        UIBackgroundModes: [audio, bluetooth-central]
```

SottoTests target — add the package so tests can construct an Opus encoder for round-trip fixtures:

```yaml
  SottoTests:
    type: bundle.unit-test
    platform: iOS
    sources:
      - path: SottoTests
    settings:
      base:
        GENERATE_INFOPLIST_FILE: YES
    dependencies:
      - target: Sotto
      - package: SwiftOpus
        product: Opus
```

- [ ] **Step 2: Create the vendored codecs file**

Create `Sotto/Omi/Vendored/OmiCodecs.swift`. This is omi-lib's `Codecs.swift` adapted: types renamed with an `Omi` prefix (`µLawCodec` → `OmiMuLawCodec` — no non-ASCII identifiers), the unused `pcmBuffer(decodedData:)` helper dropped (we convert to `[Float]` ourselves in Task 4), `print` removed, and `Sendable` added. The µ-law table below is copied VERBATIM from the vendored file — do not retype it by hand; copy it from this plan.

```swift
// Vendored and adapted from BasedHardware/omi, sdks/swift/Sources/omi-lib/helpers/Codecs.swift
// (MIT License, Copyright (c) 2024 Based Hardware Contributors).
// Adaptations: Omi-prefixed names, Sendable conformance, [Float] output path removed to
// OmiAudioDecoder, no printing.

import AVFoundation
import Opus

enum OmiCodecError: Error, Equatable {
    case invalidAudioFormat
    case decodeFailed
}

protocol OmiCodec: Sendable {
    var sampleRate: Double { get }
    init(sampleRate: Double) throws
    func decode(data: Data) throws -> Data   // PCM16 little-endian mono out
}

struct OmiPcmCodec: OmiCodec {
    let sampleRate: Double
    init(sampleRate: Double) { self.sampleRate = sampleRate }
    func decode(data: Data) -> Data { data }
}

struct OmiMuLawCodec: OmiCodec {
    // From https://web.archive.org/web/20110719132013/http://hazelware.luggle.com/tutorials/mulawcompression.html
    static let muLawToLinearTable: [Int16] = [
         -32124, -31100, -30076, -29052, -28028, -27004, -25980, -24956,
         -23932, -22908, -21884, -20860, -19836, -18812, -17788, -16764,
         -15996, -15484, -14972, -14460, -13948, -13436, -12924, -12412,
         -11900, -11388, -10876, -10364,  -9852,  -9340,  -8828,  -8316,
          -7932,  -7676,  -7420,  -7164,  -6908,  -6652,  -6396,  -6140,
          -5884,  -5628,  -5372,  -5116,  -4860,  -4604,  -4348,  -4092,
          -3900,  -3772,  -3644,  -3516,  -3388,  -3260,  -3132,  -3004,
          -2876,  -2748,  -2620,  -2492,  -2364,  -2236,  -2108,  -1980,
          -1884,  -1820,  -1756,  -1692,  -1628,  -1564,  -1500,  -1436,
          -1372,  -1308,  -1244,  -1180,  -1116,  -1052,   -988,   -924,
           -876,   -844,   -812,   -780,   -748,   -716,   -684,   -652,
           -620,   -588,   -556,   -524,   -492,   -460,   -428,   -396,
           -372,   -356,   -340,   -324,   -308,   -292,   -276,   -260,
           -244,   -228,   -212,   -196,   -180,   -164,   -148,   -132,
           -120,   -112,   -104,    -96,    -88,    -80,    -72,    -64,
            -56,    -48,    -40,    -32,    -24,    -16,     -8,     -1,
          32124,  31100,  30076,  29052,  28028,  27004,  25980,  24956,
          23932,  22908,  21884,  20860,  19836,  18812,  17788,  16764,
          15996,  15484,  14972,  14460,  13948,  13436,  12924,  12412,
          11900,  11388,  10876,  10364,   9852,   9340,   8828,   8316,
           7932,   7676,   7420,   7164,   6908,   6652,   6396,   6140,
           5884,   5628,   5372,   5116,   4860,   4604,   4348,   4092,
           3900,   3772,   3644,   3516,   3388,   3260,   3132,   3004,
           2876,   2748,   2620,   2492,   2364,   2236,   2108,   1980,
           1884,   1820,   1756,   1692,   1628,   1564,   1500,   1436,
           1372,   1308,   1244,   1180,   1116,   1052,    988,    924,
            876,    844,    812,    780,    748,    716,    684,    652,
            620,    588,    556,    524,    492,    460,    428,    396,
            372,    356,    340,    324,    308,    292,    276,    260,
            244,    228,    212,    196,    180,    164,    148,    132,
            120,    112,    104,     96,     88,     80,     72,     64,
             56,     48,     40,     32,     24,     16,      8,      0]

    let sampleRate: Double
    init(sampleRate: Double) { self.sampleRate = sampleRate }

    func decode(data: Data) -> Data {
        let i16Array = data.map { Self.muLawToLinearTable[Int($0)] }
        return i16Array.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}

/// Opus decoding via swift-opus (nelcea fork, pinned 1.0.0 — the revision omi-lib pins).
/// `Opus.Decoder` is a class holding libopus state; `@unchecked Sendable` is sound here
/// because OmiAudioSource is the only owner and calls decode from its actor context.
struct OmiOpusCodec: OmiCodec, @unchecked Sendable {
    let sampleRate: Double
    let opusDecoder: Opus.Decoder

    init(sampleRate: Double) throws {
        self.sampleRate = sampleRate
        guard let opusFormat = AVAudioFormat(
            opusPCMFormat: .int16, sampleRate: .opus16khz, channels: 1) else {
            throw OmiCodecError.invalidAudioFormat
        }
        opusDecoder = try Opus.Decoder(format: opusFormat)
    }

    func decode(data: Data) throws -> Data {
        do {
            return try opusDecoder.decodeToData(data)
        } catch {
            throw OmiCodecError.decodeFailed
        }
    }
}
```

- [ ] **Step 3: Write the failing tests**

Create `SottoTests/OmiVendoredCodecTests.swift`:

```swift
import AVFoundation
import Foundation
import Opus
import Testing
@testable import Sotto

struct OmiVendoredCodecTests {
    @Test func pcmCodecIsPassthrough() {
        let codec = OmiPcmCodec(sampleRate: 16_000)
        let input = Data([0x01, 0x02, 0x03, 0x04])
        #expect(codec.decode(data: input) == input)
    }

    @Test func muLawDecodesKnownValues() {
        let codec = OmiMuLawCodec(sampleRate: 16_000)
        // µ-law 0x00 → -32124, 0xFF → 0 (last table entry), per the vendored table.
        let decoded = codec.decode(data: Data([0x00, 0xFF]))
        let samples = decoded.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        #expect(samples == [-32124, 0])
    }

    @Test func opusRoundTripRecoversToneEnergy() throws {
        // Encode one 20 ms 16 kHz mono frame (320 samples) of a loud 440 Hz tone with
        // swift-opus, decode with OmiOpusCodec, and check the energy survived. Opus is
        // lossy — assert on RMS, not samples.
        // NOTE: if Opus.Encoder's API differs at this pin (check the swift-opus README /
        // Encoder.swift in the checked-out package), adapt THIS test only — the codec
        // under test only touches Decoder.
        let opusFormat = try #require(AVAudioFormat(
            opusPCMFormat: .int16, sampleRate: .opus16khz, channels: 1))
        let encoder = try Opus.Encoder(format: opusFormat)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: opusFormat, frameCapacity: 320))
        buffer.frameLength = 320
        let channel = try #require(buffer.int16ChannelData?[0])
        for i in 0..<320 {
            channel[i] = Int16(20_000 * sin(2 * .pi * 440 * Double(i) / 16_000))
        }
        var packet = Data(count: 1_500)
        let byteCount = try encoder.encode(buffer, to: &packet)
        let frame = packet.prefix(byteCount)

        let codec = try OmiOpusCodec(sampleRate: 16_000)
        let decoded = try codec.decode(data: Data(frame))
        let samples = decoded.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        #expect(samples.count >= 320)
        let rms = (samples.map { Double($0) * Double($0) }.reduce(0, +) / Double(samples.count))
            .squareRoot()
        #expect(rms > 2_000)   // loud tone in, non-silence out
    }
}
```

- [ ] **Step 4: Regenerate, run tests to verify they fail cleanly then pass**

```bash
xcodegen generate
xcodebuild test -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone Air' -only-testing:SottoTests/OmiVendoredCodecTests 2>&1 | tail -5
```
Expected first run: compile errors until Step 2's file exists → after both files exist: PASS. Then run the FULL suite; expected `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add project.yml Sotto/Omi/Vendored/OmiCodecs.swift SottoTests/OmiVendoredCodecTests.swift Sotto.xcodeproj
git commit -m "feat: M12 project config + vendored Omi codecs (MIT, BasedHardware/omi)"
```

---

### Task 2: Source labeling through the data model

Thread `source` from `FinalizedSegment` → `TranscriptionJob` → markdown frontmatter → `_day.json`. Everything defaults to `.phoneMic` so all existing files, persisted queues, and tests stay valid.

**Files:**
- Modify: `Sotto/Audio/AudioTypes.swift:11-13`, `Sotto/Segments/SegmentWriting.swift:7-15`, `Sotto/Transcription/TranscriptionQueue.swift` (TranscriptionJob + PersistedJob + `enqueue`), `Sotto/Transcription/TranscriptMarkdownWriter.swift:30-42`, `Sotto/Files/DayIndex.swift`, `Sotto/Files/DayIndexStore.swift:36`, `Sotto/Files/DayIndexRebuilder.swift`, `Sotto/App/AppModel.swift` (recordQueuedSegment call sites)
- Test: `SottoTests/SourceLabelingTests.swift` (new) + touch existing writer/index tests only if a compile error forces it

**Interfaces:**
- Produces: `AudioSourceType.omi`, `AudioSourceType.displayName: String` ("iPhone mic" / "Omi"), `FinalizedSegment.source: AudioSourceType` (init default `.phoneMic`), `TranscriptionJob.source: AudioSourceType`, `DaySegmentEntry.source: String?` (nil ⇒ phone mic), `DayIndexStore.recordQueuedSegment(m4aURL:startTime:duration:source:)` (source default `.phoneMic`).
- Consumed by: Task 6 (recorder stamps `FinalizedSegment.source`), Task 8 (pipeline), Task 12 (detail view).

- [ ] **Step 1: Write the failing tests**

Create `SottoTests/SourceLabelingTests.swift`:

```swift
import Foundation
import Testing
@testable import Sotto

struct SourceLabelingTests {
    @Test func audioSourceTypeHasOmiCaseAndDisplayNames() {
        #expect(AudioSourceType.omi.rawValue == "omi")
        #expect(AudioSourceType.phoneMic.displayName == "iPhone mic")
        #expect(AudioSourceType.omi.displayName == "Omi")
    }

    @Test func finalizedSegmentDefaultsToPhoneMic() {
        let seg = FinalizedSegment(
            cafURL: URL(fileURLWithPath: "/tmp/a.caf"), m4aURL: URL(fileURLWithPath: "/tmp/a.m4a"),
            startDate: Date(timeIntervalSince1970: 0), duration: 10, speechDuration: 8)
        #expect(seg.source == .phoneMic)
    }

    @Test func markdownWritesSourceLineOnlyForOmi() throws {
        // Build two jobs via the same path the queue uses; the writer must emit
        // `source: omi` for the omi job and NO source line for phoneMic (byte compat).
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let result = TranscriptionResult(
            text: "hello", segments: [], backend: .appleOnDevice)

        func write(source: AudioSourceType, name: String) throws -> String {
            var job = TranscriptionJob(
                m4aURL: tmp.appendingPathComponent("\(name).m4a"),
                cafURL: nil, startDate: Date(timeIntervalSince1970: 0),
                duration: 10, speechDuration: 8, attempts: 0, state: .pending)
            job.source = source
            let url = try TranscriptMarkdownWriter.write(result: result, job: job)
            return try String(contentsOf: url, encoding: .utf8)
        }
        // NOTE: if TranscriptionJob's memberwise init differs (check TranscriptionQueue.swift),
        // construct it exactly as that file's tests do and set `.source` after.
        let omiMD = try write(source: .omi, name: "omi")
        let micMD = try write(source: .phoneMic, name: "mic")
        #expect(omiMD.contains("\nsource: omi\n"))
        #expect(!micMD.contains("source:"))
    }

    @Test func dayIndexEntryRoundTripsSourceAndDefaultsNil() throws {
        let entry = DaySegmentEntry(
            id: "09-15-30", startTime: Date(timeIntervalSince1970: 0), duration: 10,
            backend: nil, hasAudio: true, wordCount: nil,
            transcriptionState: "queued", title: nil, source: "omi")
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(DaySegmentEntry.self, from: data)
        #expect(decoded.source == "omi")
        // Legacy JSON without the key still decodes, source nil.
        let legacy = """
        {"id":"09-15-30","startTime":0,"duration":10,"hasAudio":true,"transcriptionState":"queued"}
        """.data(using: .utf8)!
        let dec = JSONDecoder()
        let legacyEntry = try dec.decode(DaySegmentEntry.self, from: legacy)
        #expect(legacyEntry.source == nil)
    }
}
```

- [ ] **Step 2: Run to verify failure**

```bash
xcodebuild test ... -only-testing:SottoTests/SourceLabelingTests 2>&1 | tail -5
```
Expected: FAIL (compile errors: no `.omi`, no `source` members).

- [ ] **Step 3: Implement**

`Sotto/Audio/AudioTypes.swift` — replace the enum:

```swift
enum AudioSourceType: String, Codable, Sendable {
    case phoneMic
    case omi

    /// User-facing label (home header, Live Activity, Settings, detail view).
    var displayName: String {
        switch self {
        case .phoneMic: "iPhone mic"
        case .omi: "Omi"
        }
    }
}
```

`Sotto/Segments/SegmentWriting.swift` — add to `FinalizedSegment`:

```swift
struct FinalizedSegment: Sendable, Equatable {
    let cafURL: URL
    let m4aURL: URL
    let startDate: Date
    let duration: TimeInterval
    let speechDuration: TimeInterval
    /// M12: which device captured this segment. Defaulted so every pre-M12 construction
    /// site and test keeps compiling; the recorder stamps the real value (Task 6).
    var source: AudioSourceType = .phoneMic
}
```

`Sotto/Transcription/TranscriptionQueue.swift` — add `var source: AudioSourceType = .phoneMic` to `TranscriptionJob`, mirror it in `PersistedJob` (decode with `decodeIfPresent` defaulting `.phoneMic` — follow the exact pattern the struct already uses for path relativization), and in `enqueue(_ segment:)` copy `segment.source` onto the job. `enqueueSalvaged` leaves the default (`.phoneMic` — documented limitation).

`Sotto/Transcription/TranscriptMarkdownWriter.swift` — after the `backend:` line (line 34):

```swift
        if job.source != .phoneMic {
            lines.append("source: \(job.source.rawValue)")
        }
```

`Sotto/Files/DayIndex.swift` — add to `DaySegmentEntry` (below `title`):

```swift
    // M12: capture device, raw AudioSourceType value ("omi"); nil = phone mic (pre-M12
    // files have no key — same decodeIfPresent story as `title`).
    var source: String? = nil
```

`Sotto/Files/DayIndexStore.swift:36` — extend the signature (defaulted so the salvage call site compiles unchanged):

```swift
    func recordQueuedSegment(
        m4aURL: URL, startTime: Date, duration: TimeInterval,
        source: AudioSourceType = .phoneMic
    ) {
```
and set `source: source == .phoneMic ? nil : source.rawValue` when building the entry.

`Sotto/App/AppModel.swift:610-619` — the live segment handler passes it through:

```swift
            await recorder.setSegmentHandler { segment in
                Task {
                    await dayIndexStore.recordQueuedSegment(
                        m4aURL: segment.m4aURL,
                        startTime: segment.startDate,
                        duration: segment.duration,
                        source: segment.source)
                    await transcriptionQueue.enqueue(segment)
                    await transcriptionQueue.drain()
                }
            }
```

`Sotto/Files/DayIndexRebuilder.swift` — where it builds an entry from `TranscriptFile` frontmatter, read `frontmatter["source"]` into the entry's `source` (nil when absent). Follow the existing pattern used for `title`.

- [ ] **Step 4: Run the new suite, then the FULL suite**

Expected: both PASS (`** TEST SUCCEEDED **`). If any existing writer/index test fails, the byte-compat rule was violated — fix the implementation, not the old test.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: M12 source label threaded segment→job→frontmatter→day index"
```

---

### Task 3: OmiFrameAssembler

Pure transform: BLE notification bytes → complete codec frames + gap signals. No I/O, exhaustively testable.

**Files:**
- Create: `Sotto/Omi/OmiFrameAssembler.swift`, `Sotto/Omi/OmiConstants.swift`
- Test: `SottoTests/OmiFrameAssemblerTests.swift`

**Interfaces:**
- Produces:
  ```swift
  enum OmiConstants { /* UUID strings + codec values + samplesPerFrame: Int = 320 */ }
  struct OmiFrameAssembler {
      enum Output: Equatable, Sendable { case frame(Data); case gap(missingPackets: Int) }
      mutating func ingest(_ notification: Data) -> [Output]
      mutating func reset()
  }
  ```
- Consumed by: Task 5 (`OmiAudioSource`), Task 4 (`Output` is the decoder's input).

- [ ] **Step 1: Create OmiConstants.swift**

```swift
// UUIDs and framing constants from BasedHardware/omi (MIT) — firmware transport.c and
// app models.dart. See docs/superpowers/specs/2026-07-06-omi-devkit2-audio-source-design.md.
import Foundation

enum OmiConstants {
    static let audioServiceUUID = "19B10000-E8F2-537E-4F6C-D104768A1214"
    static let audioDataCharacteristicUUID = "19B10001-E8F2-537E-4F6C-D104768A1214"
    static let codecCharacteristicUUID = "19B10002-E8F2-537E-4F6C-D104768A1214"
    static let batteryServiceUUID = "180F"
    static let batteryLevelCharacteristicUUID = "2A19"
    static let deviceInfoServiceUUID = "180A"
    static let firmwareRevisionCharacteristicUUID = "2A26"

    static let notificationHeaderSize = 3
    /// One Opus frame at the firmware's documented worst case (20 ms @ 16 kHz). Used to
    /// size the silence fill for a dropped packet.
    static let samplesPerFrame = 320
    /// Codec characteristic values (char 19B10002). 8 kHz variants are rejected (spec).
    static let codecPCM16at16kHz: UInt8 = 0
    static let codecPCM16at8kHz: UInt8 = 1
    static let codecMuLawAt16kHz: UInt8 = 10
    static let codecMuLawAt8kHz: UInt8 = 11
    static let codecOpusAt16kHz: UInt8 = 20

    static let lowBatteryThresholdPercent = 15
}
```

- [ ] **Step 2: Write the failing tests**

Create `SottoTests/OmiFrameAssemblerTests.swift`:

```swift
import Foundation
import Testing
@testable import Sotto

struct OmiFrameAssemblerTests {
    /// Builds one BLE notification: [packet# LE][fragment idx][payload].
    private func notification(_ packet: UInt16, _ index: UInt8, _ payload: [UInt8]) -> Data {
        var data = Data([UInt8(packet & 0xFF), UInt8(packet >> 8), index])
        data.append(contentsOf: payload)
        return data
    }

    @Test func singleNotificationFramesEmitWhenNextArrives() {
        var assembler = OmiFrameAssembler()
        #expect(assembler.ingest(notification(0, 0, [0xAA])) == [])       // held: may be fragmented
        #expect(assembler.ingest(notification(1, 0, [0xBB])) == [.frame(Data([0xAA]))])
        #expect(assembler.ingest(notification(2, 0, [0xCC])) == [.frame(Data([0xBB]))])
    }

    @Test func fragmentsSharingPacketNumberConcatenate() {
        var assembler = OmiFrameAssembler()
        #expect(assembler.ingest(notification(7, 0, [0x01, 0x02])) == [])
        #expect(assembler.ingest(notification(7, 1, [0x03])) == [])
        #expect(assembler.ingest(notification(8, 0, [0xFF]))
            == [.frame(Data([0x01, 0x02, 0x03]))])
    }

    @Test func wraparoundIsNotAGap() {
        var assembler = OmiFrameAssembler()
        _ = assembler.ingest(notification(0xFFFF, 0, [0x01]))
        #expect(assembler.ingest(notification(0x0000, 0, [0x02])) == [.frame(Data([0x01]))])
    }

    @Test func missedPacketsReportGapThenFrame() {
        var assembler = OmiFrameAssembler()
        _ = assembler.ingest(notification(10, 0, [0x01]))
        // 11 and 12 lost in the air; 13 arrives: flush frame 10, report 2 missing, hold 13.
        #expect(assembler.ingest(notification(13, 0, [0x02]))
            == [.frame(Data([0x01])), .gap(missingPackets: 2)])
    }

    @Test func gapAcrossWraparoundCountsCorrectly() {
        var assembler = OmiFrameAssembler()
        _ = assembler.ingest(notification(0xFFFE, 0, [0x01]))
        // Next expected 0xFFFF; receiving 1 skips 0xFFFF and 0x0000 → 2 missing.
        #expect(assembler.ingest(notification(1, 0, [0x02]))
            == [.frame(Data([0x01])), .gap(missingPackets: 2)])
    }

    @Test func malformedShortNotificationIsIgnored() {
        var assembler = OmiFrameAssembler()
        #expect(assembler.ingest(Data([0x00, 0x01])) == [])   // < 3-byte header
    }

    @Test func resetForgetsSequenceState() {
        var assembler = OmiFrameAssembler()
        _ = assembler.ingest(notification(5, 0, [0x01]))
        assembler.reset()
        // Post-reset the counter re-seeds: no gap reported, previous partial frame dropped.
        #expect(assembler.ingest(notification(90, 0, [0x02])) == [])
        #expect(assembler.ingest(notification(91, 0, [0x03])) == [.frame(Data([0x02]))])
    }
}
```

- [ ] **Step 3: Run to verify failure** (compile error: no `OmiFrameAssembler`).

- [ ] **Step 4: Implement**

Create `Sotto/Omi/OmiFrameAssembler.swift`:

```swift
// Framing logic derived from BasedHardware/omi firmware transport.c and the omi-lib
// PacketCounter.swift sequence-validation approach (MIT, Based Hardware Contributors),
// adapted to report gap SIZE (for silence fill) instead of throwing.
import Foundation

/// Reassembles Omi BLE notifications into codec frames.
/// Wire format per notification: [uint16 LE packet#][uint8 fragment idx][payload…].
/// A frame is all notifications sharing one packet#; it is flushed when a notification
/// with a DIFFERENT packet# arrives (frames are small — one notification in practice).
struct OmiFrameAssembler: Sendable {
    enum Output: Equatable, Sendable {
        case frame(Data)
        case gap(missingPackets: Int)
    }

    private var currentPacketNumber: UInt16?
    private var currentFrame = Data()

    mutating func ingest(_ notification: Data) -> [Output] {
        guard notification.count >= OmiConstants.notificationHeaderSize else { return [] }
        let bytes = [UInt8](notification)
        let packetNumber = UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)
        let payload = notification.dropFirst(OmiConstants.notificationHeaderSize)

        guard let current = currentPacketNumber else {
            currentPacketNumber = packetNumber
            currentFrame = Data(payload)
            return []
        }

        if packetNumber == current {                      // another fragment of this frame
            currentFrame.append(payload)
            return []
        }

        var outputs: [Output] = [.frame(currentFrame)]
        let missing = Self.distance(from: current, to: packetNumber) - 1
        if missing > 0 {
            outputs.append(.gap(missingPackets: missing))
        }
        currentPacketNumber = packetNumber
        currentFrame = Data(payload)
        return outputs
    }

    mutating func reset() {
        currentPacketNumber = nil
        currentFrame = Data()
    }

    /// Forward distance on the wrapping uint16 counter (0xFFFF → 0x0000 is distance 1).
    private static func distance(from: UInt16, to: UInt16) -> Int {
        Int(to &- from)   // wrapping subtraction, reinterpreted as forward distance
    }
}
```

Note on `distance`: `to &- from` on UInt16 already yields the forward wrap distance (e.g. `0x0000 &- 0xFFFF == 1`); converting to `Int` keeps it positive. The `wraparoundIsNotAGap` and `gapAcrossWraparoundCountsCorrectly` tests prove it.

- [ ] **Step 5: Run the suite (new tests + full), then commit**

```bash
git add Sotto/Omi/OmiConstants.swift Sotto/Omi/OmiFrameAssembler.swift SottoTests/OmiFrameAssemblerTests.swift Sotto.xcodeproj
git commit -m "feat: M12 Omi frame assembler — fragmentation, wraparound, gap detection"
```
(Remember `xcodegen generate` before building — two new files.)

---

### Task 4: OmiAudioDecoder

Codec value → decoder; frames → `[Float]` 16 kHz mono; gaps → silence fill.

**Files:**
- Create: `Sotto/Omi/OmiAudioDecoder.swift`
- Test: `SottoTests/OmiAudioDecoderTests.swift`

**Interfaces:**
- Consumes: `OmiCodec` implementations (Task 1), `OmiFrameAssembler.Output` (Task 3).
- Produces:
  ```swift
  struct OmiAudioDecoder: Sendable {
      enum DecoderError: Error, Equatable { case unsupportedCodec(UInt8) }
      let codecValue: UInt8
      init(codecValue: UInt8) throws
      func decode(_ output: OmiFrameAssembler.Output) -> [Float]
  }
  ```
- Consumed by: Task 5.

- [ ] **Step 1: Write the failing tests**

Create `SottoTests/OmiAudioDecoderTests.swift`:

```swift
import Foundation
import Testing
@testable import Sotto

struct OmiAudioDecoderTests {
    @Test func pcm16FramesBecomeNormalizedFloats() throws {
        let decoder = try OmiAudioDecoder(codecValue: OmiConstants.codecPCM16at16kHz)
        // Int16 LE: 0, 16384 (0.5), -32768 (-1.0)
        let frame = Data([0x00, 0x00, 0x00, 0x40, 0x00, 0x80])
        let floats = decoder.decode(.frame(frame))
        #expect(floats.count == 3)
        #expect(abs(floats[0] - 0.0) < 0.0001)
        #expect(abs(floats[1] - 0.5) < 0.0001)
        #expect(abs(floats[2] - (-1.0)) < 0.0001)
    }

    @Test func muLawFramesDecodeThroughTable() throws {
        let decoder = try OmiAudioDecoder(codecValue: OmiConstants.codecMuLawAt16kHz)
        let floats = decoder.decode(.frame(Data([0x00])))   // µ-law 0x00 → -32124
        #expect(floats.count == 1)
        #expect(abs(floats[0] - (-32124.0 / 32768.0)) < 0.0001)
    }

    @Test func gapsBecomeSilenceFill() throws {
        let decoder = try OmiAudioDecoder(codecValue: OmiConstants.codecPCM16at16kHz)
        let floats = decoder.decode(.gap(missingPackets: 2))
        #expect(floats.count == 2 * OmiConstants.samplesPerFrame)
        #expect(floats.allSatisfy { $0 == 0 })
    }

    @Test func eightKilohertzCodecsAreRejected() {
        for value in [OmiConstants.codecPCM16at8kHz, OmiConstants.codecMuLawAt8kHz, UInt8(99)] {
            #expect(throws: OmiAudioDecoder.DecoderError.unsupportedCodec(value)) {
                _ = try OmiAudioDecoder(codecValue: value)
            }
        }
    }

    @Test func corruptOpusFrameYieldsSilenceNotCrash() throws {
        let decoder = try OmiAudioDecoder(codecValue: OmiConstants.codecOpusAt16kHz)
        let floats = decoder.decode(.frame(Data([0xDE, 0xAD, 0xBE])))
        // Undecodable frame → one frame of silence (same recovery as a gap).
        #expect(floats.count == OmiConstants.samplesPerFrame)
        #expect(floats.allSatisfy { $0 == 0 })
    }
}
```

- [ ] **Step 2: Run to verify failure** (no `OmiAudioDecoder`).

- [ ] **Step 3: Implement**

Create `Sotto/Omi/OmiAudioDecoder.swift`:

```swift
import Foundation

/// Maps the Omi codec characteristic value to a vendored codec and converts decoded
/// PCM16 bytes to the pipeline's normalized [Float]. Dropped packets and undecodable
/// frames become silence fill — never a crash, never a stalled stream. (True Opus PLC
/// is a post-hardware polish item; see spec "Error handling".)
struct OmiAudioDecoder: Sendable {
    enum DecoderError: Error, Equatable {
        case unsupportedCodec(UInt8)
    }

    let codecValue: UInt8
    private let codec: any OmiCodec

    init(codecValue: UInt8) throws {
        self.codecValue = codecValue
        switch codecValue {
        case OmiConstants.codecPCM16at16kHz:
            codec = OmiPcmCodec(sampleRate: 16_000)
        case OmiConstants.codecMuLawAt16kHz:
            codec = OmiMuLawCodec(sampleRate: 16_000)
        case OmiConstants.codecOpusAt16kHz:
            codec = try OmiOpusCodec(sampleRate: 16_000)
        default:
            // 8 kHz variants and unknown values: the pipeline is 16 kHz end-to-end;
            // resampling a legacy-firmware format is YAGNI (spec decision).
            throw DecoderError.unsupportedCodec(codecValue)
        }
    }

    func decode(_ output: OmiFrameAssembler.Output) -> [Float] {
        switch output {
        case .gap(let missingPackets):
            return silence(frames: missingPackets)
        case .frame(let data):
            guard let pcm16 = try? codec.decode(data: data) else {
                return silence(frames: 1)
            }
            return pcm16.withUnsafeBytes { raw in
                raw.bindMemory(to: Int16.self).map { Float(Int16(littleEndian: $0)) / 32_768.0 }
            }
        }
    }

    private func silence(frames: Int) -> [Float] {
        [Float](repeating: 0, count: frames * OmiConstants.samplesPerFrame)
    }
}
```

- [ ] **Step 4: Run new tests then FULL suite** → PASS.

- [ ] **Step 5: Commit**

```bash
git add Sotto/Omi/OmiAudioDecoder.swift SottoTests/OmiAudioDecoderTests.swift Sotto.xcodeproj
git commit -m "feat: M12 Omi audio decoder — codec selection, float conversion, silence fill"
```

---

### Task 5: OmiTransport protocol + FakeOmiTransport + OmiAudioSource

The hardware quarantine seam and the `AudioSource` actor over it.

**Files:**
- Create: `Sotto/Omi/OmiTransport.swift`, `Sotto/Omi/OmiAudioSource.swift`
- Modify: `SottoTests/Fakes.swift` (add `FakeOmiTransport`)
- Test: `SottoTests/OmiAudioSourceTests.swift`

**Interfaces:**
- Produces (exact — Tasks 7–11 consume these):
  ```swift
  enum OmiBluetoothUnavailableReason: String, Sendable, Equatable { case poweredOff, unauthorized, unsupported }

  enum OmiTransportEvent: Sendable, Equatable {
      case connecting
      case connected(codecValue: UInt8)
      case audioNotification(Data)
      case batteryLevel(Int)                 // percent 0–100
      case disconnected
      case bluetoothUnavailable(OmiBluetoothUnavailableReason)
  }

  struct OmiDiscovery: Sendable, Equatable, Identifiable { let id: UUID; let name: String; let rssi: Int }

  protocol OmiTransport: Sendable {
      func scan() async -> AsyncStream<OmiDiscovery>
      func stopScan() async
      /// Connect to the peripheral and MAINTAIN the connection (immediate pending
      /// re-connect on disconnect) until stopEvents(). Repeatable after stopEvents().
      func events(deviceID: UUID) async -> AsyncStream<OmiTransportEvent>
      func stopEvents() async
  }

  enum OmiConnectionState: Sendable, Equatable {
      case disconnected, connecting, connected, streaming
      case unavailable(OmiBluetoothUnavailableReason)
  }

  protocol ConnectableAudioSource: AudioSource {
      /// New independent stream per call (multicast) — FailoverAudioSource and AppModel
      /// both observe.
      func connectionStates() async -> AsyncStream<OmiConnectionState>
  }

  actor OmiAudioSource: ConnectableAudioSource {
      init(transport: any OmiTransport, deviceID: UUID)
      func batteryLevels() -> AsyncStream<Int>
      private(set) var setupFailureMessage: String?   // unsupported-codec surfacing
      // + AudioSource conformance
  }
  ```

- [ ] **Step 1: Create OmiTransport.swift** with the types above verbatim (protocol + events + discovery + `OmiConnectionState` + `ConnectableAudioSource`).

- [ ] **Step 2: Add FakeOmiTransport to SottoTests/Fakes.swift**

Follow the file's existing fake conventions (actors, recorded calls). Add:

```swift
actor FakeOmiTransport: OmiTransport {
    private var eventContinuation: AsyncStream<OmiTransportEvent>.Continuation?
    private var scanContinuation: AsyncStream<OmiDiscovery>.Continuation?
    private(set) var eventsCallCount = 0
    private(set) var stopEventsCallCount = 0
    private(set) var lastDeviceID: UUID?

    func scan() -> AsyncStream<OmiDiscovery> {
        let (stream, continuation) = AsyncStream.makeStream(of: OmiDiscovery.self)
        scanContinuation = continuation
        return stream
    }
    func stopScan() { scanContinuation?.finish(); scanContinuation = nil }

    func events(deviceID: UUID) -> AsyncStream<OmiTransportEvent> {
        eventsCallCount += 1
        lastDeviceID = deviceID
        let (stream, continuation) = AsyncStream.makeStream(of: OmiTransportEvent.self)
        eventContinuation = continuation
        return stream
    }
    func stopEvents() {
        stopEventsCallCount += 1
        eventContinuation?.finish()
        eventContinuation = nil
    }

    // Test drivers
    func emit(_ event: OmiTransportEvent) { eventContinuation?.yield(event) }
    func emitDiscovery(_ d: OmiDiscovery) { scanContinuation?.yield(d) }

    /// Emits a well-formed audio notification wrapping `payload` at `packet#`.
    func emitAudio(packet: UInt16, index: UInt8 = 0, payload: [UInt8]) {
        var data = Data([UInt8(packet & 0xFF), UInt8(packet >> 8), index])
        data.append(contentsOf: payload)
        emit(.audioNotification(data))
    }
}
```

- [ ] **Step 3: Write the failing tests**

Create `SottoTests/OmiAudioSourceTests.swift`. PCM16 codec (value 0) keeps fixtures human-readable; 4096-sample chunking means tests feed 4096 samples = 8192 payload bytes across notifications — use a helper.

```swift
import Foundation
import Testing
@testable import Sotto

struct OmiAudioSourceTests {
    private func makeSource() -> (OmiAudioSource, FakeOmiTransport) {
        let transport = FakeOmiTransport()
        let source = OmiAudioSource(transport: transport, deviceID: UUID())
        return (source, transport)
    }

    /// Feeds `sampleCount` PCM16 samples of value 0x0100 (Float ≈ 0.0078) as sequential
    /// single-fragment notifications of 160 samples each, then one trailing notification
    /// (the assembler holds the last frame until the next arrives).
    private func feedSamples(_ transport: FakeOmiTransport, from packet: UInt16, count: Int) async {
        // The assembler holds the newest frame until the NEXT packet# arrives, so to get
        // ≥ count samples through, send enough notifications that the FLUSHED frames
        // (sent − 1) cover count: e.g. count 4096 → 25 full frames isn't enough (4000),
        // 26 flushed frames = 4160 ≥ 4096 → send 27 notifications.
        let flushedFramesNeeded = (count + 159) / 160 + 1   // ceil + slack for the held frame
        for i in 0...flushedFramesNeeded {
            let payload = [UInt8](repeating: 0, count: 160 * 2).enumerated()
                .map { (offset, _) in offset % 2 == 1 ? UInt8(0x01) : UInt8(0x00) }
            await transport.emitAudio(packet: packet &+ UInt16(i), payload: payload)
        }
    }

    @Test func chunksFlowAfterConnectAndAudio() async throws {
        let (source, transport) = makeSource()
        let stream = try await source.start()
        await transport.emit(.connecting)
        await transport.emit(.connected(codecValue: OmiConstants.codecPCM16at16kHz))
        await feedSamples(transport, from: 0, count: 4096)

        var iterator = stream.makeAsyncIterator()
        let chunk = await iterator.next()
        #expect(chunk?.samples.count == 4096)
        #expect(abs((chunk?.samples[0] ?? 0) - Float(0x0100) / 32_768.0) < 0.0001)
        await source.stop()
    }

    @Test func connectionStatesProgressToStreaming() async throws {
        let (source, transport) = makeSource()
        let states = await source.connectionStates()
        _ = try await source.start()
        var iterator = states.makeAsyncIterator()

        await transport.emit(.connecting)
        #expect(await iterator.next() == .connecting)
        await transport.emit(.connected(codecValue: OmiConstants.codecOpusAt16kHz))
        #expect(await iterator.next() == .connected)
        await transport.emitAudio(packet: 0, payload: [0x00])
        #expect(await iterator.next() == .streaming)     // first audio ⇒ streaming
        await transport.emit(.disconnected)
        #expect(await iterator.next() == .disconnected)
        await source.stop()
    }

    @Test func unsupportedCodecSurfacesFailureAndNeverStreams() async throws {
        let (source, transport) = makeSource()
        let states = await source.connectionStates()
        _ = try await source.start()
        var iterator = states.makeAsyncIterator()
        await transport.emit(.connected(codecValue: OmiConstants.codecPCM16at8kHz))
        #expect(await iterator.next() == .connected)
        await transport.emitAudio(packet: 0, payload: [0x00, 0x00])
        // No .streaming state, and the failure is legible for Settings:
        let message = await source.setupFailureMessage
        #expect(message?.contains("codec") == true)
        await source.stop()
    }

    @Test func batteryLevelsStreamAndLatestIsStored() async throws {
        let (source, transport) = makeSource()
        let levels = await source.batteryLevels()
        _ = try await source.start()
        var iterator = levels.makeAsyncIterator()
        await transport.emit(.batteryLevel(80))
        #expect(await iterator.next() == 80)
        await source.stop()
    }

    @Test func stopContractHolds() async throws {
        let (source, transport) = makeSource()
        // Safe when never started:
        await source.stop()
        // Finishes the stream:
        let stream = try await source.start()
        await source.stop()
        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next() == nil)
        // Idempotent:
        await source.stop()
        #expect(await transport.stopEventsCallCount >= 1)
        // Restartable (resumeFromInterruption calls stop() then start()):
        let stream2 = try await source.start()
        await transport.emit(.connected(codecValue: OmiConstants.codecPCM16at16kHz))
        await feedSamples(transport, from: 0, count: 4096)
        var iterator2 = stream2.makeAsyncIterator()
        #expect(await iterator2.next() != nil)
        await source.stop()
    }

    @Test func reconnectResetsAssemblerSoNoPhantomGap() async throws {
        let (source, transport) = makeSource()
        let stream = try await source.start()
        await transport.emit(.connected(codecValue: OmiConstants.codecPCM16at16kHz))
        await feedSamples(transport, from: 100, count: 4096)
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next()
        await transport.emit(.disconnected)
        // Reconnect: firmware restarts its counter — must NOT be treated as a huge gap.
        await transport.emit(.connected(codecValue: OmiConstants.codecPCM16at16kHz))
        await feedSamples(transport, from: 0, count: 4096)
        let chunk = await iterator.next()
        // A phantom gap would inject 320×N zeros; all samples must be the 0x0100 value.
        #expect(chunk?.samples.allSatisfy { abs($0 - Float(0x0100) / 32_768.0) < 0.0001 } == true)
        await source.stop()
    }
}
```

- [ ] **Step 4: Run to verify failure**, then implement `Sotto/Omi/OmiAudioSource.swift`:

```swift
import Foundation

/// AudioSource over an OmiTransport: raw BLE notifications → frames → floats → 4096-sample
/// AudioChunks. Connection lifecycle (reconnect) lives in the TRANSPORT; failover timing
/// lives in FailoverAudioSource. This actor is a decode pipeline plus state relay.
actor OmiAudioSource: ConnectableAudioSource {
    nonisolated let sourceType: AudioSourceType = .omi
    nonisolated var isAvailable: Bool { true }

    enum OmiSourceError: Error { case alreadyStarted }

    private let transport: any OmiTransport
    private let deviceID: UUID

    private var continuation: AsyncStream<AudioChunk>.Continuation?
    private var eventTask: Task<Void, Never>?
    private var assembler = OmiFrameAssembler()
    private var decoder: OmiAudioDecoder?
    private var chunker = SampleChunker()
    private var hasStreamedSinceConnect = false

    private var stateContinuations: [UUID: AsyncStream<OmiConnectionState>.Continuation] = [:]
    private var batteryContinuations: [UUID: AsyncStream<Int>.Continuation] = [:]
    private(set) var latestBatteryLevel: Int?
    private(set) var setupFailureMessage: String?

    init(transport: any OmiTransport, deviceID: UUID) {
        self.transport = transport
        self.deviceID = deviceID
    }

    func start() async throws -> AsyncStream<AudioChunk> {
        guard eventTask == nil else { throw OmiSourceError.alreadyStarted }
        let (stream, continuation) = AsyncStream.makeStream(of: AudioChunk.self)
        self.continuation = continuation
        let events = await transport.events(deviceID: deviceID)
        eventTask = Task { [weak self] in
            for await event in events {
                await self?.handle(event)
            }
        }
        return stream
    }

    func stop() async {
        eventTask?.cancel()
        eventTask = nil
        await transport.stopEvents()
        continuation?.finish()
        continuation = nil
        assembler.reset()
        chunker.reset()
        decoder = nil
        hasStreamedSinceConnect = false
    }

    func connectionStates() -> AsyncStream<OmiConnectionState> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: OmiConnectionState.self)
        stateContinuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeStateContinuation(id) }
        }
        return stream
    }

    func batteryLevels() -> AsyncStream<Int> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: Int.self)
        batteryContinuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeBatteryContinuation(id) }
        }
        return stream
    }

    private func removeStateContinuation(_ id: UUID) { stateContinuations[id] = nil }
    private func removeBatteryContinuation(_ id: UUID) { batteryContinuations[id] = nil }

    private func yieldState(_ state: OmiConnectionState) {
        for continuation in stateContinuations.values { continuation.yield(state) }
    }

    private func handle(_ event: OmiTransportEvent) {
        switch event {
        case .connecting:
            yieldState(.connecting)
        case .connected(let codecValue):
            // Fresh session: firmware restarts its packet counter; stale fragments and
            // chunker remainders belong to the previous connection.
            assembler.reset()
            chunker.reset()
            hasStreamedSinceConnect = false
            do {
                decoder = try OmiAudioDecoder(codecValue: codecValue)
                setupFailureMessage = nil
            } catch {
                decoder = nil
                setupFailureMessage = "Omi firmware uses an unsupported audio codec (value \(codecValue))."
            }
            yieldState(.connected)
        case .audioNotification(let data):
            guard let decoder else { return }
            if !hasStreamedSinceConnect {
                hasStreamedSinceConnect = true
                yieldState(.streaming)
            }
            for output in assembler.ingest(data) {
                let samples = decoder.decode(output)
                guard !samples.isEmpty else { continue }
                for chunk in chunker.append(samples: samples, hostTime: mach_absolute_time()) {
                    continuation?.yield(chunk)
                }
            }
        case .batteryLevel(let percent):
            latestBatteryLevel = percent
            for continuation in batteryContinuations.values { continuation.yield(percent) }
        case .disconnected:
            hasStreamedSinceConnect = false
            yieldState(.disconnected)
        case .bluetoothUnavailable(let reason):
            hasStreamedSinceConnect = false
            yieldState(.unavailable(reason))
        }
    }
}
```

- [ ] **Step 5: Run new tests + FULL suite** → PASS. `xcodegen generate` first (new files).

- [ ] **Step 6: Commit**

```bash
git add Sotto/Omi/OmiTransport.swift Sotto/Omi/OmiAudioSource.swift SottoTests/OmiAudioSourceTests.swift SottoTests/Fakes.swift Sotto.xcodeproj
git commit -m "feat: M12 OmiTransport seam + OmiAudioSource actor"
```

---

### Task 6: Recorder — active source stamping + segment rollover

The recorder learns which source is active (stamps `FinalizedSegment.source`) and gains `rollover(to:)`: finalize any open segment, stay listening.

**Files:**
- Modify: `Sotto/Recorder/RecorderTypes.swift:36-44` (protocol), `Sotto/Recorder/RecorderStateMachine.swift`
- Modify: `SottoTests/Fakes.swift` (fake recorder gets the two methods)
- Test: `SottoTests/RecorderStateMachineTests.swift` (extend)

**Interfaces:**
- Produces (exact, consumed by Task 8):
  ```swift
  protocol SegmentRecording: Sendable {
      // existing four methods unchanged, plus:
      /// Sets the label stamped on subsequently finalized segments. No state transition.
      func setActiveSource(_ source: AudioSourceType) async
      /// Source switch: finalize any open segment (same path as the silence-timeout
      /// finalize), set the new source, and continue in .listening if currently in an
      /// active state. In .idle/.interrupted this only sets the source.
      func rollover(to source: AudioSourceType) async -> RecorderSnapshot
  }
  ```

- [ ] **Step 1: Read `Sotto/Recorder/RecorderStateMachine.swift` in full.** Identify: the stored config/writer state, the private finalize helper the silence-timeout path uses (the one that builds `FinalizedSegment` and calls the segment handler), and how `beginListening` re-enters `.listening`. The implementation below reuses those exact internals — adapt names to what you find.

- [ ] **Step 2: Write the failing tests** (append to `SottoTests/RecorderStateMachineTests.swift`, reusing that file's existing builder/fixture helpers — read them first; the sketch below shows intent, adapt construction to the file's established helpers):

```swift
@Test func rolloverFinalizesOpenSegmentWithOldSourceAndKeepsListening() async throws {
    // Arrange: drive the machine into .recording with enough speech to beat the
    // min-segment guard (reuse the file's existing "record a valid segment" helper).
    // Set the active source to .omi first:
    await recorder.setActiveSource(.omi)
    // ... drive to .recording ...
    let snapshot = await recorder.rollover(to: .phoneMic)
    #expect(snapshot.state == .listening)
    // The finalized segment carries the OLD source:
    #expect(capturedSegments.last?.source == .omi)
    // Subsequent segments carry the NEW source:
    // ... drive another segment to finalize ...
    #expect(capturedSegments.last?.source == .phoneMic)
}

@Test func rolloverWhileListeningJustSwitchesSource() async throws {
    _ = await recorder.beginListening()
    let snapshot = await recorder.rollover(to: .omi)
    #expect(snapshot.state == .listening)
    // No segment was finalized:
    #expect(capturedSegments.isEmpty)
}

@Test func rolloverWhileIdleOnlySetsSource() async throws {
    let snapshot = await recorder.rollover(to: .omi)
    #expect(snapshot.state == .idle)
}
```

- [ ] **Step 3: Run to verify failure** (protocol methods missing).

- [ ] **Step 4: Implement.** In `RecorderTypes.swift` add the two protocol requirements with the doc comments from Interfaces. In `RecorderStateMachine`: add `private var activeSource: AudioSourceType = .phoneMic`; stamp `source: activeSource` where `FinalizedSegment` is constructed; implement:

```swift
    func setActiveSource(_ source: AudioSourceType) {
        activeSource = source
    }

    func rollover(to source: AudioSourceType) -> RecorderSnapshot {
        switch state {
        case .recording, .silence:
            // Same finalize path as the silence-timeout close (min-length guard included),
            // then return to listening — the session continues on the new source.
            finalizeOpenSegment()          // ← adapt to the actual private helper name
            state = .listening
        case .listening, .idle, .interrupted:
            break                          // nothing open; just relabel
        }
        activeSource = source
        return snapshot(lastEvent: "Source → \(source.displayName)")   // adapt to the actual snapshot builder
    }
```

Update the fake recorder in `SottoTests/Fakes.swift` with recording implementations of both methods (append to its call log, matching the file's conventions).

- [ ] **Step 5: Run extended suite + FULL suite** → PASS.

- [ ] **Step 6: Commit**

```bash
git add Sotto/Recorder SottoTests && git commit -m "feat: M12 recorder rollover(to:) + active-source stamping"
```

---

### Task 7: FailoverAudioSource

The supervisor: prefers Omi, falls back to phone mic after grace, returns after hysteresis, emits change events.

**Files:**
- Create: `Sotto/Omi/FailoverAudioSource.swift`
- Modify: `SottoTests/Fakes.swift` (add `FakeConnectableAudioSource`, `FakeAudioSource` if none exists)
- Test: `SottoTests/FailoverAudioSourceTests.swift`

**Interfaces:**
- Consumes: `ConnectableAudioSource` (Task 5), `AudioSource`.
- Produces (exact, consumed by Task 8):
  ```swift
  struct FailoverConfig: Sendable {
      var startupRace: Duration = .seconds(3)
      var reconnectGrace: Duration = .seconds(3)
      var returnHysteresis: Duration = .seconds(10)
  }
  enum AudioSourceChangeReason: Sendable, Equatable {
      case initial, omiDisconnected, omiRecovered, captureUnavailable
  }
  struct AudioSourceChange: Sendable, Equatable {
      let source: AudioSourceType?        // nil ⇒ nothing capturing (captureUnavailable)
      let reason: AudioSourceChangeReason
  }
  protocol SourceSwitchingAudioSource: AudioSource {
      func sourceChanges() async -> AsyncStream<AudioSourceChange>
      var activeSourceType: AudioSourceType? { get async }
  }
  /// Route-change forwarding seam (AppModel wiring, Task 10).
  protocol RouteChangeHandling: Sendable { func rebuildTap() async throws }
  actor FailoverAudioSource: SourceSwitchingAudioSource {
      init(omi: any ConnectableAudioSource, phoneMic: any AudioSource,
           config: FailoverConfig = FailoverConfig())
      func handleRouteChange() async throws   // forwards to phoneMic when it's active
  }
  ```
  Also: `extension PhoneMicAudioSource: RouteChangeHandling {}` (it already has `rebuildTap()`).

**Behavior contract (encode in tests):**
1. `start()` starts the Omi source immediately and returns the outward stream. If Omi reaches `.streaming` before `startupRace` elapses → activate Omi (`.initial`). Otherwise → start phone mic, activate it (`.initial`); Omi keeps trying.
2. Omi chunks are forwarded ONLY while Omi is active; the Omi source keeps running (and its chunks are drained and dropped) while the phone mic is active — its stream must not buffer unboundedly.
3. On Omi `.disconnected`/`.unavailable` while Omi active: wait `reconnectGrace`; if not `.streaming` again → start phone mic, emit `.omiDisconnected`. If phone mic `start()` THROWS → emit `AudioSourceChange(source: nil, reason: .captureUnavailable)` and keep supervising (a later Omi `.streaming` recovers via `.omiRecovered`).
4. On Omi `.streaming` while phone mic active: wait `returnHysteresis`; if no disconnect during the window → stop phone mic, activate Omi, emit `.omiRecovered`. A disconnect within the window cancels the return.
5. `stop()`: stops both children, finishes outward + change streams, idempotent, safe unstarted, restartable.

- [ ] **Step 1: Add fakes to Fakes.swift**

```swift
actor FakeConnectableAudioSource: ConnectableAudioSource {
    nonisolated let sourceType: AudioSourceType = .omi
    nonisolated var isAvailable: Bool { true }
    private var continuation: AsyncStream<AudioChunk>.Continuation?
    private var stateContinuations: [UUID: AsyncStream<OmiConnectionState>.Continuation] = [:]
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func start() async throws -> AsyncStream<AudioChunk> {
        startCount += 1
        let (stream, c) = AsyncStream.makeStream(of: AudioChunk.self)
        continuation = c
        return stream
    }
    func stop() {
        continuation?.finish(); continuation = nil
    }
    func connectionStates() -> AsyncStream<OmiConnectionState> {
        let id = UUID()
        let (stream, c) = AsyncStream.makeStream(of: OmiConnectionState.self)
        stateContinuations[id] = c
        return stream
    }
    // Test drivers
    func setState(_ s: OmiConnectionState) { for c in stateContinuations.values { c.yield(s) } }
    func emitChunk(_ chunk: AudioChunk) { continuation?.yield(chunk) }
}

actor FakeSimpleAudioSource: AudioSource {
    nonisolated let sourceType: AudioSourceType = .phoneMic
    nonisolated var isAvailable: Bool { true }
    var startError: Error?
    private var continuation: AsyncStream<AudioChunk>.Continuation?
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func setStartError(_ error: Error?) { startError = error }
    func start() async throws -> AsyncStream<AudioChunk> {
        startCount += 1
        if let startError { throw startError }
        let (stream, c) = AsyncStream.makeStream(of: AudioChunk.self)
        continuation = c
        return stream
    }
    func stop() { continuation?.finish(); continuation = nil; stopCount += 1 }
    func emitChunk(_ chunk: AudioChunk) { continuation?.yield(chunk) }
}
```
(If `Fakes.swift` already has an equivalent simple fake source, reuse it instead of adding `FakeSimpleAudioSource`.)

- [ ] **Step 2: Write the failing tests**

Create `SottoTests/FailoverAudioSourceTests.swift`. Tests use millisecond timings; each waits generously (500 ms ceilings) to stay deterministic on CI.

```swift
import Foundation
import Testing
@testable import Sotto

struct FailoverAudioSourceTests {
    private let fastConfig = FailoverConfig(
        startupRace: .milliseconds(80),
        reconnectGrace: .milliseconds(80),
        returnHysteresis: .milliseconds(120))

    private func makeChunk(_ value: Float = 0.5) -> AudioChunk {
        AudioChunk(samples: [Float](repeating: value, count: 4096), hostTime: 1)
    }

    /// Collects change events into an actor-safe box for assertions.
    private func collectChanges(_ source: FailoverAudioSource) async -> AsyncStream<AudioSourceChange>.AsyncIterator {
        await source.sourceChanges().makeAsyncIterator()
    }

    @Test func omiWinsStartupRaceWhenStreaming() async throws {
        let omi = FakeConnectableAudioSource()
        let mic = FakeSimpleAudioSource()
        let failover = FailoverAudioSource(omi: omi, phoneMic: mic, config: fastConfig)
        var changes = await collectChanges(failover)
        let stream = try await failover.start()
        await omi.setState(.streaming)
        #expect(await changes.next() == AudioSourceChange(source: .omi, reason: .initial))
        await omi.emitChunk(makeChunk())
        var it = stream.makeAsyncIterator()
        #expect(await it.next()?.samples.count == 4096)
        #expect(await mic.startCount == 0)   // phone mic never touched
        await failover.stop()
    }

    @Test func phoneMicWinsWhenOmiSilentPastRace() async throws {
        let omi = FakeConnectableAudioSource()
        let mic = FakeSimpleAudioSource()
        let failover = FailoverAudioSource(omi: omi, phoneMic: mic, config: fastConfig)
        var changes = await collectChanges(failover)
        let stream = try await failover.start()
        // No omi streaming within 80 ms:
        #expect(await changes.next() == AudioSourceChange(source: .phoneMic, reason: .initial))
        await mic.emitChunk(makeChunk())
        var it = stream.makeAsyncIterator()
        #expect(await it.next() != nil)
        await failover.stop()
    }

    @Test func disconnectPastGraceFallsBackAndRecoveryReturns() async throws {
        let omi = FakeConnectableAudioSource()
        let mic = FakeSimpleAudioSource()
        let failover = FailoverAudioSource(omi: omi, phoneMic: mic, config: fastConfig)
        var changes = await collectChanges(failover)
        _ = try await failover.start()
        await omi.setState(.streaming)
        #expect(await changes.next()?.reason == .initial)

        await omi.setState(.disconnected)
        #expect(await changes.next() == AudioSourceChange(source: .phoneMic, reason: .omiDisconnected))

        await omi.setState(.streaming)          // stays stable through hysteresis
        #expect(await changes.next() == AudioSourceChange(source: .omi, reason: .omiRecovered))
        #expect(await mic.stopCount >= 1)
        await failover.stop()
    }

    @Test func blipWithinGraceDoesNotSwitch() async throws {
        let omi = FakeConnectableAudioSource()
        let mic = FakeSimpleAudioSource()
        let failover = FailoverAudioSource(omi: omi, phoneMic: mic, config: fastConfig)
        var changes = await collectChanges(failover)
        _ = try await failover.start()
        await omi.setState(.streaming)
        #expect(await changes.next()?.reason == .initial)
        await omi.setState(.disconnected)
        try await Task.sleep(for: .milliseconds(20))     // < 80 ms grace
        await omi.setState(.streaming)
        try await Task.sleep(for: .milliseconds(200))
        #expect(await mic.startCount == 0)               // never fell back
        await failover.stop()
    }

    @Test func flapDuringHysteresisCancelsReturn() async throws {
        let omi = FakeConnectableAudioSource()
        let mic = FakeSimpleAudioSource()
        let failover = FailoverAudioSource(omi: omi, phoneMic: mic, config: fastConfig)
        var changes = await collectChanges(failover)
        _ = try await failover.start()
        await omi.setState(.streaming)
        _ = await changes.next()                          // initial
        await omi.setState(.disconnected)
        _ = await changes.next()                          // omiDisconnected
        await omi.setState(.streaming)
        try await Task.sleep(for: .milliseconds(30))      // < 120 ms hysteresis
        await omi.setState(.disconnected)                 // flap: cancels the return
        try await Task.sleep(for: .milliseconds(250))
        #expect(await failover.activeSourceType == .phoneMic)
        await failover.stop()
    }

    @Test func micFailureEmitsCaptureUnavailableThenOmiRecovers() async throws {
        struct Boom: Error {}
        let omi = FakeConnectableAudioSource()
        let mic = FakeSimpleAudioSource()
        await mic.setStartError(Boom())
        let failover = FailoverAudioSource(omi: omi, phoneMic: mic, config: fastConfig)
        var changes = await collectChanges(failover)
        _ = try await failover.start()
        await omi.setState(.streaming)
        _ = await changes.next()                          // initial
        await omi.setState(.disconnected)
        #expect(await changes.next() == AudioSourceChange(source: nil, reason: .captureUnavailable))
        await omi.setState(.streaming)
        #expect(await changes.next() == AudioSourceChange(source: .omi, reason: .omiRecovered))
        await failover.stop()
    }

    @Test func stopContractHolds() async throws {
        let omi = FakeConnectableAudioSource()
        let mic = FakeSimpleAudioSource()
        let failover = FailoverAudioSource(omi: omi, phoneMic: mic, config: fastConfig)
        await failover.stop()                              // safe unstarted
        let stream = try await failover.start()
        await failover.stop()
        var it = stream.makeAsyncIterator()
        #expect(await it.next() == nil)                   // stream finished
        await failover.stop()                              // idempotent
        _ = try await failover.start()                     // restartable
        await failover.stop()
    }
}
```

- [ ] **Step 3: Run to verify failure**, then implement `Sotto/Omi/FailoverAudioSource.swift`:

```swift
import Foundation

struct FailoverConfig: Sendable {
    var startupRace: Duration = .seconds(3)
    var reconnectGrace: Duration = .seconds(3)
    var returnHysteresis: Duration = .seconds(10)
}

enum AudioSourceChangeReason: Sendable, Equatable {
    case initial, omiDisconnected, omiRecovered, captureUnavailable
}

struct AudioSourceChange: Sendable, Equatable {
    let source: AudioSourceType?
    let reason: AudioSourceChangeReason
}

protocol SourceSwitchingAudioSource: AudioSource {
    func sourceChanges() async -> AsyncStream<AudioSourceChange>
    var activeSourceType: AudioSourceType? { get async }
}

protocol RouteChangeHandling: Sendable {
    func rebuildTap() async throws
}

extension PhoneMicAudioSource: RouteChangeHandling {}

/// Prefers the Omi whenever it streams; phone mic otherwise. Presents ONE chunk stream;
/// the pipeline can't tell sources apart (by design — SPEC audio source layer). Timer
/// tasks (startup race / grace / hysteresis) are event-cancelled, so a state event and
/// its timer can never both fire.
actor FailoverAudioSource: SourceSwitchingAudioSource {
    nonisolated let sourceType: AudioSourceType = .omi   // informational: the preferred source
    nonisolated var isAvailable: Bool { true }

    private let omi: any ConnectableAudioSource
    private let phoneMic: any AudioSource
    private let config: FailoverConfig

    private(set) var activeSourceType: AudioSourceType?
    private var outward: AsyncStream<AudioChunk>.Continuation?
    private var changeContinuations: [UUID: AsyncStream<AudioSourceChange>.Continuation] = [:]

    private var omiPumpTask: Task<Void, Never>?
    private var micPumpTask: Task<Void, Never>?
    private var stateTask: Task<Void, Never>?
    private var startupTask: Task<Void, Never>?
    private var graceTask: Task<Void, Never>?
    private var returnTask: Task<Void, Never>?
    private var started = false

    init(omi: any ConnectableAudioSource, phoneMic: any AudioSource,
         config: FailoverConfig = FailoverConfig()) {
        self.omi = omi
        self.phoneMic = phoneMic
        self.config = config
    }

    func start() async throws -> AsyncStream<AudioChunk> {
        guard !started else { throw PhoneMicAudioSource.AudioSourceError.alreadyStarted }
        started = true
        activeSourceType = nil
        let (stream, continuation) = AsyncStream.makeStream(of: AudioChunk.self)
        outward = continuation

        let states = await omi.connectionStates()
        let omiStream = try await omi.start()
        // Always drain the omi stream; forward only while omi is active (prevents
        // unbounded buffering while on fallback).
        omiPumpTask = Task { [weak self] in
            for await chunk in omiStream {
                await self?.forward(chunk, from: .omi)
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
        started = false
        for task in [omiPumpTask, micPumpTask, stateTask, startupTask, graceTask, returnTask] {
            task?.cancel()
        }
        omiPumpTask = nil; micPumpTask = nil; stateTask = nil
        startupTask = nil; graceTask = nil; returnTask = nil
        await omi.stop()
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

    private func handle(_ state: OmiConnectionState) async {
        switch state {
        case .streaming:
            graceTask?.cancel(); graceTask = nil
            if activeSourceType == nil {                  // won the startup race
                startupTask?.cancel(); startupTask = nil
                activate(.omi, reason: .initial)
            } else if activeSourceType == .phoneMic, returnTask == nil {
                returnTask = Task { [weak self, config] in
                    try? await Task.sleep(for: config.returnHysteresis)
                    guard !Task.isCancelled else { return }
                    await self?.returnHysteresisElapsed()
                }
            }
        case .disconnected, .unavailable:
            returnTask?.cancel(); returnTask = nil
            if activeSourceType == .omi, graceTask == nil {
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
        guard started, activeSourceType == .omi else { return }
        await activatePhoneMic(reason: .omiDisconnected)
    }

    private func returnHysteresisElapsed() async {
        returnTask = nil
        guard started, activeSourceType == .phoneMic else {
            // Also the recovery path from captureUnavailable (activeSourceType nil):
            if started, activeSourceType == nil { activate(.omi, reason: .omiRecovered) }
            return
        }
        micPumpTask?.cancel(); micPumpTask = nil
        await phoneMic.stop()
        activate(.omi, reason: .omiRecovered)
    }

    private func activate(_ source: AudioSourceType, reason: AudioSourceChangeReason) {
        activeSourceType = source
        emit(AudioSourceChange(source: source, reason: reason))
    }

    private func activatePhoneMic(reason: AudioSourceChangeReason) async {
        do {
            let stream = try await phoneMic.start()
            micPumpTask = Task { [weak self] in
                for await chunk in stream {
                    await self?.forward(chunk, from: .phoneMic)
                }
            }
            activate(.phoneMic, reason: reason)
        } catch {
            activeSourceType = nil
            emit(AudioSourceChange(source: nil, reason: .captureUnavailable))
        }
    }
}
```

Note the `captureUnavailable` recovery subtlety: after a failed mic start, `activeSourceType` is nil, so the next `.streaming` event's `activeSourceType == nil` branch in `handle` activates Omi directly with `.initial`… which is wrong — it must be `.omiRecovered`. Handle it by tracking `hasEmittedInitial`: once any change has been emitted, a nil-active activation uses `.omiRecovered`. Encode exactly this in the `micFailureEmitsCaptureUnavailableThenOmiRecovers` test (it asserts `.omiRecovered`), and implement with:

```swift
    private var hasEmittedInitial = false
    // in activate(): if reason == .initial && hasEmittedInitial { emit .omiRecovered instead }
    // set hasEmittedInitial = true on every emit; reset to false in start()
```

- [ ] **Step 4: Run new tests + FULL suite** → PASS (these are timing tests — run the suite twice to check for flake; if flaky, raise the test config's ceilings, never `sleep` in implementation).

- [ ] **Step 5: Commit**

```bash
git add Sotto/Omi/FailoverAudioSource.swift SottoTests/FailoverAudioSourceTests.swift SottoTests/Fakes.swift Sotto.xcodeproj Sotto/Audio/PhoneMicAudioSource.swift
git commit -m "feat: M12 FailoverAudioSource — grace, hysteresis, capture-unavailable"
```

---

### Task 8: Pipeline integration — rollover on source change + notifications

`ListeningPipeline` observes source changes, rolls the recorder over, publishes the active source, and fires the notifications.

**Files:**
- Modify: `Sotto/Pipeline/ListeningPipeline.swift`, `Sotto/Notifications/` (the file holding `NotificationScheduling`), `Sotto/LiveActivity/LiveActivityControlling.swift`, `Sotto/LiveActivity/SottoActivityAttributes.swift`
- Modify: `SottoTests/Fakes.swift` (extend notification + live-activity fakes)
- Test: `SottoTests/ListeningPipelineSourceTests.swift`

**Interfaces:**
- Produces:
  - `ListeningPipeline.activeSourceType: AudioSourceType?` (published, drives home header Task 12)
  - `NotificationScheduling` additions:
    ```swift
    func scheduleSourceFallbackNotification() async     // "Omi disconnected — continuing on iPhone mic. …"
    func scheduleCaptureUnavailableNotification() async // "Recording stopped — Omi disconnected and the microphone could not start."
    func scheduleOmiLowBatteryNotification(level: Int) async
    ```
  - `SottoActivityAttributes.ContentState.sourceLabel: String?` (default nil — wire-format additive)
  - `LiveActivityControlling.update(phase:conversationCount:sourceLabel:)` (sourceLabel defaulted so existing call sites compile)

- [ ] **Step 1: Extend the protocols + concrete implementations**

`SottoActivityAttributes.ContentState`:

```swift
    struct ContentState: Codable, Hashable {
        var phase: Phase
        var conversationCount: Int
        /// M12: capture-source label ("Omi" / "iPhone mic"); nil pre-M12 or phone-mic-only.
        var sourceLabel: String? = nil
    }
```

`LiveActivityControlling.update` becomes `func update(phase: SottoActivityAttributes.Phase, conversationCount: Int, sourceLabel: String?)`; give the protocol an extension overload `update(phase:conversationCount:)` forwarding `sourceLabel: nil` so existing call sites and fakes stay small. `SottoLiveActivityController.update` passes it into `ContentState`.

`NotificationScheduling` gains the three methods; `UserNotificationScheduler` implements them following the exact `schedulePausedNotification` pattern with identifiers `"sotto.sourceFallback"`, `"sotto.captureUnavailable"`, `"sotto.omiLowBattery"` and copy:
- fallback: title "Omi disconnected", body "Recording continues on the iPhone microphone — audio may be muffled if the phone is in a pocket."
- unavailable: title "Recording stopped", body "The Omi disconnected and the iPhone microphone could not start. Open Sotto to resume."
- low battery: title "Omi battery low", body "About \(level)% left — charge it soon to keep recording."

Update the notification fake in `Fakes.swift` to record the new calls.

- [ ] **Step 2: Write the failing tests**

Create `SottoTests/ListeningPipelineSourceTests.swift`, reusing the fake recorder + fake notification scheduler from `Fakes.swift` and `FakeConnectableAudioSource`/`FakeSimpleAudioSource` from Task 7 (construct a real `FailoverAudioSource` with a fast config — this doubles as the integration test of the seam):

```swift
import Foundation
import Testing
@testable import Sotto

@MainActor
struct ListeningPipelineSourceTests {
    @Test func fallbackRollsRecorderOverAndNotifies() async throws {
        let omi = FakeConnectableAudioSource()
        let mic = FakeSimpleAudioSource()
        let failover = FailoverAudioSource(
            omi: omi, phoneMic: mic,
            config: FailoverConfig(startupRace: .milliseconds(60),
                                   reconnectGrace: .milliseconds(60),
                                   returnHysteresis: .milliseconds(80)))
        let recorder = FakeSegmentRecorder()          // adapt to Fakes.swift's actual name
        let notifications = FakeNotificationScheduler()
        let pipeline = ListeningPipeline(source: failover, recorder: recorder,
                                         notifications: notifications)
        await pipeline.start()
        await omi.setState(.streaming)
        try await Task.sleep(for: .milliseconds(30))
        #expect(pipeline.activeSourceType == .omi)

        await omi.setState(.disconnected)
        try await Task.sleep(for: .milliseconds(200))
        #expect(pipeline.activeSourceType == .phoneMic)
        #expect(await recorder.rolloverCalls.last == .phoneMic)
        #expect(await notifications.sourceFallbackCount == 1)

        await omi.setState(.streaming)
        try await Task.sleep(for: .milliseconds(250))
        #expect(pipeline.activeSourceType == .omi)
        #expect(await recorder.rolloverCalls.last == .omi)
        await pipeline.stop()
    }

    @Test func captureUnavailableNotifiesLoudly() async throws {
        struct Boom: Error {}
        let omi = FakeConnectableAudioSource()
        let mic = FakeSimpleAudioSource()
        await mic.setStartError(Boom())
        let failover = FailoverAudioSource(
            omi: omi, phoneMic: mic,
            config: FailoverConfig(startupRace: .milliseconds(60),
                                   reconnectGrace: .milliseconds(60),
                                   returnHysteresis: .milliseconds(80)))
        let notifications = FakeNotificationScheduler()
        let pipeline = ListeningPipeline(source: failover, recorder: FakeSegmentRecorder(),
                                         notifications: notifications)
        await pipeline.start()
        await omi.setState(.streaming)
        try await Task.sleep(for: .milliseconds(30))
        await omi.setState(.disconnected)
        try await Task.sleep(for: .milliseconds(200))
        #expect(await notifications.captureUnavailableCount == 1)
        #expect(pipeline.activeSourceType == nil)
        await pipeline.stop()
    }

    @Test func plainSourceHasNilActiveSourceUntilStartThenPhoneMic() async throws {
        // A non-switching source (plain fake) sets activeSourceType from sourceType.
        let mic = FakeSimpleAudioSource()
        let pipeline = ListeningPipeline(source: mic, recorder: FakeSegmentRecorder())
        #expect(pipeline.activeSourceType == nil)
        await pipeline.start()
        #expect(pipeline.activeSourceType == .phoneMic)
        await pipeline.stop()
        #expect(pipeline.activeSourceType == nil)
    }
}
```

Adapt fake type names to what `Fakes.swift` actually declares (read it first); add `rolloverCalls: [AudioSourceType]` to the fake recorder and the three counters to the notification fake if missing.

- [ ] **Step 3: Implement in ListeningPipeline.swift**

Additions (weave into the existing structure — the pattern for each is already in the file):

```swift
    /// M12: which device is currently capturing (nil when idle or nothing capturing).
    private(set) var activeSourceType: AudioSourceType?
    private var sourceEventTask: Task<Void, Never>?
```

In `start()` (and `resumeFromInterruption()`), after `pumpTask` is created:

```swift
            if let switching = source as? any SourceSwitchingAudioSource {
                sourceEventTask = Task { [weak self] in
                    for await change in await switching.sourceChanges() {
                        await self?.handleSourceChange(change)
                    }
                }
            } else {
                activeSourceType = source.sourceType
                Task { await recorder.setActiveSource(source.sourceType) }
            }
```

New private method:

```swift
    private func handleSourceChange(_ change: AudioSourceChange) async {
        switch change.reason {
        case .initial:
            if let source = change.source {
                activeSourceType = source
                await recorder.setActiveSource(source)
                log("Capturing via \(source.displayName)")
            }
        case .omiDisconnected:
            guard let source = change.source else { return }
            let snapshot = await recorder.rollover(to: source)
            activeSourceType = source
            apply(snapshot)
            log("Omi disconnected — continuing on iPhone mic")
            await notifications?.scheduleSourceFallbackNotification()
        case .omiRecovered:
            guard let source = change.source else { return }
            let snapshot = await recorder.rollover(to: source)
            activeSourceType = source
            apply(snapshot)
            log("Omi reconnected")
        case .captureUnavailable:
            activeSourceType = nil
            log("Nothing capturing — Omi gone and mic unavailable")
            await notifications?.scheduleCaptureUnavailableNotification()
        }
        pushLiveActivitySource()
    }

    private func pushLiveActivitySource() {
        if let phase = activityPhase(for: status) {
            liveActivity?.update(phase: phase, conversationCount: finalizedCount,
                                 sourceLabel: activeSourceType?.displayName)
        }
    }
```

In `performHalt`, cancel + nil `sourceEventTask` next to `pumpTask`, and clear `activeSourceType = nil` in the `.stop` branch. In `apply()`, pass `sourceLabel: activeSourceType?.displayName` at the existing two `liveActivity?.update` call sites (use the new parameter, keep the extension overload for tests that don't care).

- [ ] **Step 4: Run new tests + FULL suite** → PASS.

- [ ] **Step 5: Commit**

```bash
git add Sotto/Pipeline Sotto/Notifications Sotto/LiveActivity SottoTests
git commit -m "feat: M12 pipeline source-change handling — rollover, notifications, source label"
```

---

### Task 9: CoreBluetoothOmiTransport

The one hardware-facing file. No automated tests (everything it feeds is fake-tested); the deliverable is a complete, compiling implementation reviewed against the protocol contract, exercised later by the hardware checklist (Task 13).

**Files:**
- Create: `Sotto/Omi/CoreBluetoothOmiTransport.swift`

**Interfaces:**
- Consumes: `OmiTransport`, `OmiTransportEvent`, `OmiConstants` (Tasks 3/5).

- [ ] **Step 1: Implement**

```swift
import CoreBluetooth
import Foundation

/// Real OmiTransport over CoreBluetooth. Design notes:
/// - Scans by SERVICE UUID (never name — survives the Friend→Omi rebrand and is required
///   for background scanning).
/// - Maintains the connection: on disconnect it immediately re-issues connect(), which
///   CoreBluetooth holds pending until the peripheral reappears — no scan loop.
/// - State restoration identifier is set so iOS can relaunch the app on BLE activity
///   after a background kill (spec stretch S2; willRestoreState reattaches minimally).
/// - All CBCentralManagerDelegate callbacks arrive on `queue`; every mutation happens
///   there, and results cross to consumers only via Sendable AsyncStream yields.
final class CoreBluetoothOmiTransport: NSObject, OmiTransport, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.decanlys.Sotto.omi-ble")
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var targetDeviceID: UUID?
    private var eventContinuation: AsyncStream<OmiTransportEvent>.Continuation?
    private var scanContinuation: AsyncStream<OmiDiscovery>.Continuation?
    private var audioCharacteristic: CBCharacteristic?

    private var audioServiceUUID: CBUUID { CBUUID(string: OmiConstants.audioServiceUUID) }

    // MARK: OmiTransport

    func scan() async -> AsyncStream<OmiDiscovery> {
        let (stream, continuation) = AsyncStream.makeStream(of: OmiDiscovery.self)
        queue.async { [self] in
            scanContinuation?.finish()
            scanContinuation = continuation
            ensureCentral()
            startScanIfPoweredOn()
        }
        return stream
    }

    func stopScan() async {
        queue.async { [self] in
            central?.stopScan()
            scanContinuation?.finish()
            scanContinuation = nil
        }
    }

    func events(deviceID: UUID) async -> AsyncStream<OmiTransportEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: OmiTransportEvent.self)
        queue.async { [self] in
            eventContinuation?.finish()
            eventContinuation = continuation
            targetDeviceID = deviceID
            ensureCentral()
            connectIfPoweredOn()
        }
        return stream
    }

    func stopEvents() async {
        queue.async { [self] in
            if let peripheral { central?.cancelPeripheralConnection(peripheral) }
            peripheral = nil
            targetDeviceID = nil
            audioCharacteristic = nil
            eventContinuation?.finish()
            eventContinuation = nil
        }
    }

    // MARK: internals (queue-confined)

    private func ensureCentral() {
        guard central == nil else { return }
        central = CBCentralManager(
            delegate: self, queue: queue,
            options: [CBCentralManagerOptionRestoreIdentifierKey: "com.decanlys.Sotto.omi"])
    }

    private func startScanIfPoweredOn() {
        guard let central, central.state == .poweredOn else { return }
        central.scanForPeripherals(withServices: [audioServiceUUID])
    }

    private func connectIfPoweredOn() {
        guard let central, central.state == .poweredOn, let targetDeviceID else { return }
        if let known = central.retrievePeripherals(withIdentifiers: [targetDeviceID]).first {
            peripheral = known
            known.delegate = self
            eventContinuation?.yield(.connecting)
            central.connect(known)
        } else {
            // Paired device iOS no longer knows (e.g. after Bluetooth reset): rediscover
            // by service UUID, connect on sight (didDiscover checks targetDeviceID).
            eventContinuation?.yield(.connecting)
            central.scanForPeripherals(withServices: [audioServiceUUID])
        }
    }
}

extension CoreBluetoothOmiTransport: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            startScanIfPoweredOn()   // no-op unless a scan consumer exists
            connectIfPoweredOn()
        case .poweredOff:
            eventContinuation?.yield(.bluetoothUnavailable(.poweredOff))
        case .unauthorized:
            eventContinuation?.yield(.bluetoothUnavailable(.unauthorized))
        case .unsupported:
            eventContinuation?.yield(.bluetoothUnavailable(.unsupported))
        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        // Minimal S2 support: reattach restored peripherals so a background BLE relaunch
        // has a delegate. Full pipeline restart from restoration is user-verified (Task 13).
        if let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] {
            peripheral = restored.first
            peripheral?.delegate = self
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        scanContinuation?.yield(OmiDiscovery(
            id: peripheral.identifier,
            name: peripheral.name ?? "Omi device",
            rssi: RSSI.intValue))
        if peripheral.identifier == targetDeviceID {
            central.stopScan()
            self.peripheral = peripheral
            peripheral.delegate = self
            central.connect(peripheral)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([
            audioServiceUUID,
            CBUUID(string: OmiConstants.batteryServiceUUID),
        ])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        eventContinuation?.yield(.disconnected)
        if peripheral.identifier == targetDeviceID {
            central.connect(peripheral)      // pending retry, completes on reappearance
        }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        audioCharacteristic = nil
        eventContinuation?.yield(.disconnected)
        if peripheral.identifier == targetDeviceID {
            eventContinuation?.yield(.connecting)
            central.connect(peripheral)      // immediate pending re-connect (spec)
        }
    }
}

extension CoreBluetoothOmiTransport: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for service in peripheral.services ?? [] {
            if service.uuid == audioServiceUUID {
                peripheral.discoverCharacteristics([
                    CBUUID(string: OmiConstants.audioDataCharacteristicUUID),
                    CBUUID(string: OmiConstants.codecCharacteristicUUID),
                ], for: service)
            } else if service.uuid == CBUUID(string: OmiConstants.batteryServiceUUID) {
                peripheral.discoverCharacteristics(
                    [CBUUID(string: OmiConstants.batteryLevelCharacteristicUUID)], for: service)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for characteristic in service.characteristics ?? [] {
            switch characteristic.uuid {
            case CBUUID(string: OmiConstants.codecCharacteristicUUID):
                peripheral.readValue(for: characteristic)   // codec FIRST — gates decode setup
            case CBUUID(string: OmiConstants.audioDataCharacteristicUUID):
                audioCharacteristic = characteristic        // notify enabled after codec read
            case CBUUID(string: OmiConstants.batteryLevelCharacteristicUUID):
                peripheral.readValue(for: characteristic)
                peripheral.setNotifyValue(true, for: characteristic)   // newer fw notifies
            default:
                break
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let value = characteristic.value else { return }
        switch characteristic.uuid {
        case CBUUID(string: OmiConstants.codecCharacteristicUUID):
            let codecValue = value.first ?? OmiConstants.codecOpusAt16kHz
            eventContinuation?.yield(.connected(codecValue: codecValue))
            if let audioCharacteristic {
                peripheral.setNotifyValue(true, for: audioCharacteristic)
            }
        case CBUUID(string: OmiConstants.audioDataCharacteristicUUID):
            eventContinuation?.yield(.audioNotification(value))
        case CBUUID(string: OmiConstants.batteryLevelCharacteristicUUID):
            if let level = value.first {
                eventContinuation?.yield(.batteryLevel(Int(level)))
            }
        default:
            break
        }
    }
}
```

- [ ] **Step 2: Build + full suite** (`xcodegen generate` first). Expected: compiles clean, all tests pass (nothing exercises this class yet).

- [ ] **Step 3: Self-review against the transport contract** (Task 5 Interfaces): repeatable `events()` after `stopEvents()` (yes — fresh continuation each call), scan/events independent, every disconnect path yields an event. Fix anything that doesn't hold.

- [ ] **Step 4: Commit**

```bash
git add Sotto/Omi/CoreBluetoothOmiTransport.swift Sotto.xcodeproj
git commit -m "feat: M12 CoreBluetooth transport — service-UUID scan, pending reconnect, restoration"
```

---

### Task 10: OmiDeviceStore + AppModel composition

Pairing persistence, the composition branch at the single construction site, pipeline rebuild on pair/forget, interruption gating, battery observation.

**Files:**
- Create: `Sotto/Omi/OmiDeviceStore.swift`
- Modify: `Sotto/App/AppModel.swift` (construction at :621, observer wiring at :628-655, new members)
- Test: `SottoTests/OmiDeviceStoreTests.swift`, extend `SottoTests/AppModelTests.swift`

**Interfaces:**
- Produces:
  ```swift
  struct PairedOmiDevice: Codable, Equatable, Sendable { let id: UUID; let name: String }
  final class OmiDeviceStore: Sendable {
      init(defaults: UserDefaults = .standard)
      var device: PairedOmiDevice? { get }
      func pair(_ device: PairedOmiDevice)
      func forget()
  }
  ```
  AppModel: `var omiBatteryLevel: Int?`, `var omiConnectionState: OmiConnectionState?`, `var pairedOmiName: String?`, `var omiSetupFailure: String?`, `func pairOmi(_ discovery: OmiDiscovery)`, `func forgetOmi()`, `func makeOmiScanTransport() -> any OmiTransport`.

- [ ] **Step 1: OmiDeviceStore + tests**

Store as JSON in UserDefaults key `"pairedOmiDevice"`. Tests: pair→device round-trips; forget→nil; fresh defaults→nil. (Use `UserDefaults(suiteName: #function)` + `removePersistentDomain` per the project's existing settings-test pattern — check how `AppSettings` tests do it.)

```swift
import Foundation

/// Persists the single paired Omi (spec: auto-prefer one device; pair/forget only).
final class OmiDeviceStore: Sendable {
    private static let key = "pairedOmiDevice"
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var device: PairedOmiDevice? {
        guard let data = defaults.data(forKey: Self.key) else { return nil }
        return try? JSONDecoder().decode(PairedOmiDevice.self, from: data)
    }
    func pair(_ device: PairedOmiDevice) {
        defaults.set(try? JSONEncoder().encode(device), forKey: Self.key)
    }
    func forget() { defaults.removeObject(forKey: Self.key) }
}

struct PairedOmiDevice: Codable, Equatable, Sendable {
    let id: UUID
    let name: String
}
```

- [ ] **Step 2: AppModel composition (read the surrounding code first; keep its DI style)**

Replace `AppModel.swift:621` (`let source = PhoneMicAudioSource()`) with a factory + branch, and keep a handle for wiring:

```swift
            // M12: auto-prefer a paired Omi (spec "Selection model") — failover to the
            // phone mic is the selection logic; no paired device ⇒ exactly the old path.
            let omiStore = OmiDeviceStore()
            var omiSource: OmiAudioSource?
            let source: any AudioSource
            if let paired = omiStore.device {
                let omi = OmiAudioSource(
                    transport: CoreBluetoothOmiTransport(), deviceID: paired.id)
                omiSource = omi
                source = FailoverAudioSource(omi: omi, phoneMic: PhoneMicAudioSource())
                pairedOmiName = paired.name
            } else {
                source = PhoneMicAudioSource()
                pairedOmiName = nil
            }
```

Observer rewiring (same block, adjusted):
- `onInterruptionBegan` / `onInterruptionEndedShouldResume` / `onMediaServicesReset`: gate on the phone mic actually capturing — for a `FailoverAudioSource` capture that means `await failover.activeSourceType == .phoneMic`; for the plain source, current behavior. Implement via `let switching = source as? FailoverAudioSource` captured weakly in the closures:
  ```swift
            sessionObserver.onInterruptionBegan = { [weak newPipeline, weak switching] in
                if let switching, await switching.activeSourceType != .phoneMic { return }
                await newPipeline?.interrupt()
            }
  ```
- `onRouteChangeDeviceUnavailable`: when composed, call `try await switching.handleRouteChange()` instead of `source.rebuildTap()`; on throw, `interrupt()` as today. Plain path unchanged.

Battery + connection observation (only when `omiSource != nil`), after pipeline construction:

```swift
            if let omiSource {
                omiObservationTask = Task { [weak self] in
                    let states = await omiSource.connectionStates()
                    let batteries = await omiSource.batteryLevels()
                    async let stateLoop: Void = {
                        for await state in states {
                            // setupFailureMessage becomes readable once the codec char has
                            // been processed — refresh it alongside each state change.
                            let failure = await omiSource.setupFailureMessage
                            await MainActor.run {
                                self?.omiConnectionState = state
                                self?.omiSetupFailure = failure
                            }
                        }
                    }()
                    for await level in batteries {
                        await MainActor.run { self?.applyOmiBattery(level) }
                    }
                    await stateLoop
                }
            }
```

New AppModel stored members (declare with the other `private var` state):

```swift
    private(set) var omiBatteryLevel: Int?
    private(set) var omiConnectionState: OmiConnectionState?
    private(set) var pairedOmiName: String?
    private(set) var omiSetupFailure: String?
    private var omiObservationTask: Task<Void, Never>?
```
```

with:

```swift
    private var lowBatteryNotified = false
    private func applyOmiBattery(_ level: Int) {
        omiBatteryLevel = level
        if level <= OmiConstants.lowBatteryThresholdPercent, !lowBatteryNotified {
            lowBatteryNotified = true
            Task { await UserNotificationScheduler().scheduleOmiLowBatteryNotification(level: level) }
        }
        if level > OmiConstants.lowBatteryThresholdPercent + 10 { lowBatteryNotified = false }
    }
```
(If AppModel already holds a `notifications` scheduler reference, use it instead of constructing `UserNotificationScheduler` — check while reading.)

Pair/forget with pipeline rebuild (idle-only, mirroring the Settings "changes apply after launch" convention otherwise):

```swift
    func pairOmi(_ discovery: OmiDiscovery) {
        OmiDeviceStore().pair(PairedOmiDevice(id: discovery.id, name: discovery.name))
        Task { await rebuildPipelineIfIdle() }
    }

    func forgetOmi() {
        OmiDeviceStore().forget()
        omiBatteryLevel = nil
        omiConnectionState = nil
        Task { await rebuildPipelineIfIdle() }
    }

    /// Re-runs source construction + pipeline wiring when nothing is listening. If a
    /// session is live, the change applies on the next Start (existing Settings rule).
    private func rebuildPipelineIfIdle() async {
        guard pipeline?.status == .idle || pipeline == nil else { return }
        omiObservationTask?.cancel(); omiObservationTask = nil
        setupTask = nil            // allow performSetUp to run again
        await ensureSetUp()
    }
```

**Check `performSetUp` for idempotence hazards before relying on re-run** (it already guards salvage/launch work behaviorally, but read it: the launch sweep, heartbeat check, and salvage loop will re-run — each is a no-op the second time by construction; verify, and if any is not, extract the source+pipeline construction into a helper both paths call instead).

`makeOmiScanTransport()` just returns `CoreBluetoothOmiTransport()` — the pair sheet owns its scan transport lifecycle (Task 11).

- [ ] **Step 3: Tests**

`OmiDeviceStoreTests` as above. In `AppModelTests`, add: pairing writes the store and `pairedOmiName` becomes non-nil after rebuild; forget clears it (drive through `pairOmi`/`forgetOmi` with an injected defaults suite if AppModel's tests have a defaults seam — read `AppModelTests.swift` first and follow its construction pattern; if AppModel hardcodes `.standard`, add a `omiStoreOverride` test seam matching the existing `segmentRootOverride` pattern).

- [ ] **Step 4: Run FULL suite** → PASS. **Step 5: Commit**

```bash
git add Sotto/Omi/OmiDeviceStore.swift Sotto/App/AppModel.swift SottoTests Sotto.xcodeproj
git commit -m "feat: M12 pairing store + AppModel composition, rebuild, battery observation"
```

---

### Task 11: Settings UI — Omi Device section + pair sheet

**Files:**
- Modify: `Sotto/App/SettingsView.swift` (listeningSection, ~line 68)
- Create: `Sotto/App/OmiPairSheet.swift`

**Interfaces:**
- Consumes: `AppModel.pairOmi/forgetOmi/makeOmiScanTransport/omiBatteryLevel/omiConnectionState/pairedOmiName/omiSetupFailure` (Task 10), `OmiDiscovery` (Task 5).

- [ ] **Step 1: Replace the static audio-source row**

In `listeningSection`, replace `LabeledContent("Audio source", value: "Phone microphone")` with:

```swift
            if let name = model.pairedOmiName {
                LabeledContent("Audio source", value: "\(name) + iPhone mic fallback")
            } else {
                LabeledContent("Audio source", value: "iPhone microphone")
            }
```

Add a new section below Listening (follow the file's section style):

```swift
    private var omiSection: some View {
        Section("Omi Device") {
            if let name = model.pairedOmiName {
                LabeledContent("Device", value: name)
                LabeledContent("Status", value: omiStatusLabel)
                if let battery = model.omiBatteryLevel {
                    LabeledContent("Battery", value: "\(battery)%")
                }
                if let failure = model.omiSetupFailure {
                    Text(failure).font(.caption).foregroundStyle(.red)
                }
                Button("Forget This Device", role: .destructive) { showForgetConfirm = true }
                    .confirmationDialog("Forget \(name)?", isPresented: $showForgetConfirm) {
                        Button("Forget", role: .destructive) { model.forgetOmi() }
                    } message: {
                        Text("Sotto will stop connecting to it and use the iPhone microphone.")
                    }
            } else {
                Button("Pair Omi Device…") { showPairSheet = true }
                Text("Wear an Omi pendant and Sotto records from it automatically, falling back to the iPhone mic when it's out of range.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var omiStatusLabel: String {
        switch model.omiConnectionState {
        case .streaming: "Streaming"
        case .connected: "Connected"
        case .connecting: "Connecting…"
        case .disconnected, nil: "Not connected"
        case .unavailable(.poweredOff): "Bluetooth is off"
        case .unavailable(.unauthorized): "Bluetooth permission needed"
        case .unavailable(.unsupported): "Bluetooth unavailable"
        }
    }
```

with `@State private var showPairSheet = false` / `showForgetConfirm = false`, `.sheet(isPresented: $showPairSheet) { OmiPairSheet(model: model) }`, and `omiSection` inserted after `listeningSection` in the body.

- [ ] **Step 2: Create OmiPairSheet.swift**

```swift
import SwiftUI

/// Scans for Omi devices (by service UUID) and pairs the tapped one. The sheet owns its
/// transport: scanning stops when it disappears.
struct OmiPairSheet: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var discoveries: [OmiDiscovery] = []
    @State private var scanTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            List {
                if discoveries.isEmpty {
                    HStack {
                        ProgressView()
                        Text("Looking for Omi devices nearby…").foregroundStyle(.secondary)
                    }
                }
                ForEach(discoveries) { discovery in
                    Button {
                        model.pairOmi(discovery)
                        dismiss()
                    } label: {
                        LabeledContent(discovery.name, value: "\(discovery.rssi) dBm")
                    }
                }
            }
            .navigationTitle("Pair Omi")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .task {
            let transport = model.makeOmiScanTransport()
            scanTask = Task {
                for await discovery in await transport.scan() {
                    if !discoveries.contains(where: { $0.id == discovery.id }) {
                        discoveries.append(discovery)
                    }
                }
            }
            // Cancellation path: stop scanning when the sheet goes away.
            await withTaskCancellationHandler {
                await scanTask?.value
            } onCancel: {
                Task { await transport.stopScan() }
            }
        }
    }
}
```

- [ ] **Step 3: Build + FULL suite** (`xcodegen generate` — new file). UI is thin over tested model API; no new unit tests beyond compiling. Manually eyeball in the simulator: Settings shows "Pair Omi Device…" (simulator has no BLE — the sheet shows the scanning row forever; that's expected).

- [ ] **Step 4: Commit**

```bash
git add Sotto/App/SettingsView.swift Sotto/App/OmiPairSheet.swift Sotto.xcodeproj
git commit -m "feat: M12 Settings Omi section + pair sheet"
```

---

### Task 12: Surfacing — home header, widget label, detail view source

**Files:**
- Modify: `Sotto/App/ContentView.swift` (status header), `SottoWidgets/` (the Live Activity view file — find the view rendering `ContentState`), `Sotto/App/ConversationDetailView.swift`
- Test: extend `SottoTests/AppModelTests.swift` or view-model-level tests only if logic (not layout) is added

- [ ] **Step 1: Home header.** Read `ContentView.swift`'s status header (M9 layout). Where the status label renders (e.g. "Listening"), append the source when a switching session is live:

```swift
    // In the header's status text builder:
    if let source = model.pipeline?.activeSourceType, model.pairedOmiName != nil {
        Text("\(statusLabel) · \(source.displayName)")
    } else {
        Text(statusLabel)
    }
```
Adapt to the actual view structure — the rule: source suffix appears ONLY when an Omi is paired (phone-mic-only users see no change).

- [ ] **Step 2: Widget.** In the SottoWidgets Live Activity view, render `context.state.sourceLabel` as a caption near the phase label when non-nil (same conditional-suffix pattern). Keep it to one `Text` — lock-screen space is tight.

- [ ] **Step 3: Detail view.** In `ConversationDetailView`, where metadata rows render (duration/backend), add a "Source" row when the entry's `source` is non-nil: `LabeledContent("Source", value: AudioSourceType(rawValue: entry.source ?? "")?.displayName ?? entry.source!)`. Read the file first; follow its metadata-row pattern.

- [ ] **Step 4: Bluetooth-off banner (spec "UI & surfacing").** Read ContentView's existing banner block (micDenied is the template — full text + action button, stacked). Add a banner shown when an Omi is paired AND `model.omiConnectionState` is `.unavailable(.poweredOff)` or `.unavailable(.unauthorized)`:

```swift
    // Alongside the micDenied banner, same visual weight:
    if model.pairedOmiName != nil,
       case .unavailable(let reason) = model.omiConnectionState ?? .disconnected,
       reason == .poweredOff || reason == .unauthorized {
        BannerView(   // ← use the file's actual banner component/pattern
            text: reason == .poweredOff
                ? "Bluetooth is off — your Omi can't connect. Recording uses the iPhone mic."
                : "Sotto needs Bluetooth permission to use your Omi. Recording uses the iPhone mic.",
            actionTitle: "Open Settings",
            action: { UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!) })
    }
```
Adapt to the actual banner construction in the file (there is no `BannerView` type — mirror how the micDenied banner is built). Capture continues on the phone mic; the banner is informational.

- [ ] **Step 5: Build + FULL suite → PASS. Commit**

```bash
git add Sotto/App SottoWidgets && git commit -m "feat: M12 source surfacing — home header, Live Activity, detail view"
```

---

### Task 13: Docs + hardware verification checklist

**Files:**
- Modify: `docs/SPEC.md` (audio source layer section)
- Create: `docs/superpowers/plans/2026-07-06-m12-hardware-verification.md`

- [ ] **Step 1: SPEC.md.** In the "Audio source layer" section: update `AudioSourceType` to the shipped two-case enum, and add a short "Omi Devkit 2 source (M12)" paragraph: transport → assembler → decoder → chunker layering, failover policy (3 s grace / 10 s hysteresis / segment rollover at switch), auto-prefer selection model, and a pointer to the design spec. In the pipeline diagram's first line, note the source can be `FailoverAudioSource(Omi, phone mic)`.

- [ ] **Step 2: Hardware verification checklist** — create the file with this content (user-owned; requires the physical Devkit 2 + an iPhone):

```markdown
# M12 — Omi Devkit 2 Hardware Verification (user-owned)

Run when the Devkit 2 arrives. Automated coverage ends at FakeOmiTransport; these
checks are the only proof the real radio path works. Log results per item.

## Spike S1 — background mic activation (do FIRST; iPhone only, no Omi needed)
- [ ] Simulate: app backgrounded + listening via a (fake or real) BLE source, then force
      a fallback: does `PhoneMicAudioSource.start()` succeed from the background with no
      user tap? (Instrument via the captureUnavailable notification: if fallback works
      you get the "Omi disconnected — continuing on iPhone mic" notification; if iOS
      refuses you get "Recording stopped".)
- [ ] If iOS refuses: file a follow-up to convert auto-fallback to the actionable
      notification path (spec's documented degradation) — the failover/notification
      plumbing already supports it.

## Basic path
- [ ] Pair via Settings → device appears by service UUID scan, name shown.
- [ ] Codec characteristic reads 20 (Opus/16 kHz) on current firmware; Settings shows
      no codec failure. (Older firmware: PCM16 also acceptable.)
- [ ] Live streaming: speak near the pendant → segment records, transcribes; audio
      sounds clean (no clicks — if clicky, revisit silence-fill vs PLC).
- [ ] Frontmatter shows `source: omi`; detail view shows "Omi".

## Failover
- [ ] Walk away with the pendant (phone stationary) → within ~6 s: fallback
      notification + home header shows "iPhone mic" + old segment closed.
- [ ] Walk back → within ~15 s of BLE reconnect: header shows "Omi", segment rolled.
- [ ] Radio-blip test (pendant in a metal box for 1–2 s) → NO segment split.
- [ ] Battery level shows in Settings; drain below 15% → one low-battery notification.

## All-day soak
- [ ] Overnight background session streaming from the pendant: no app kill, Live
      Activity stays truthful, day folder populated.
- [ ] Force-kill the app while streaming → does iOS relaunch on BLE data (state
      restoration, stretch S2)? Record behavior either way; if it relaunches but the
      pipeline doesn't resume, file the S2 follow-up task.
```

- [ ] **Step 3: Commit**

```bash
git add docs/SPEC.md docs/superpowers/plans/2026-07-06-m12-hardware-verification.md
git commit -m "docs: M12 SPEC audio-source update + hardware verification checklist"
```

---

## Completion criteria

- Full suite green (`** TEST SUCCEEDED **`), zero new warnings.
- Phone-mic-only behavior byte-identical (no paired device ⇒ old construction path, old markdown bytes).
- The M12 epic is code-complete but NOT closable until the hardware checklist (Task 13's file) has been run on a real Devkit 2 — track that file as the epic's exit gate.

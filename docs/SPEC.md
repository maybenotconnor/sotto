# Sotto — Developer Spec v3.1

> An iOS 26 app that listens all day, records only when people talk, and saves each conversation as text. Fully on-device by default. No subscription.

## What it does

Tap **Start** once in the morning. The app backgrounds. Audio flows from the active source (phone mic in MVP; architecture supports future external devices). Silero VAD detects speech in real time on the Neural Engine. When speech starts, it records audio (including a 1 s pre-roll from a ring buffer). When silence exceeds a configurable timeout, it closes that segment as one "conversation," transcribes it on-device via SpeechAnalyzer (or optionally via Deepgram for diarized transcription), and saves the result as a timestamped markdown file. A Live Activity on the lock screen shows the current state with a pause/resume button. You end the day with a folder of transcripts.

**Platform reality the design accepts up front:**

1. Any phone call, FaceTime, or Siri activation stops the mic (iOS interrupts the session; this is also what keeps the app legal for phone calls in Connecticut). Recovery is one tap on the Live Activity or the fallback notification — but it is a tap the user must make, potentially many times a day.
2. If iOS kills the app in the background (memory pressure, crash), there is no relaunch mechanism for audio apps. Listening silently stops. The Live Activity going stale is the user-visible signal; on next launch the app detects the unclean shutdown and shows the gap.
3. There is no App Store precedent for an all-day _phone-mic_ ambient recorder (existing players record on wearables/Watch). App Review is a genuine project risk — but development and testing stay fully local (dev builds + TestFlight internal need no review); Apple first sees the app at pre-launch milestone M7.

---

## Pipeline

```
AudioSource (phone mic in MVP; future BLE device / Watch)
    → hardware-format tap → AVAudioConverter → 16 kHz mono Float32
    → AudioChunk ([Float], 4096 samples = 256 ms) via AsyncStream
    → VadManager.processStreamingChunk (Silero v6, CoreML/ANE, FluidAudio)
    → .speechStart event?
        YES → flush 1 s ring buffer + live audio into crash-safe .m4a writer
              (keep writing through short silences)
    → .speechEnd + app-level silence timeout expired?
        YES → finalize .m4a
            → enqueue TranscriptionService.transcribe(file)   ← queue, never inline
            → save .md + update _day.json
            → return to Listening
```

---

## Audio source layer

Audio input is abstracted behind a protocol so the capture device is swappable without touching the downstream pipeline. The protocol deals in **value-type sample chunks, not `AVAudioPCMBuffer`**: engine tap buffers must not be retained across async boundaries, `AVAudioPCMBuffer` is not `Sendable` under Swift 6 strict concurrency, and plain `[Float]` is exactly what the VAD consumes. It also keeps AVFoundation types out of the seam a future BLE (Opus → PCM) source plugs into.

```swift
struct AudioChunk: Sendable {
    let samples: [Float]        // 16 kHz mono, normalized
    let hostTime: UInt64        // capture timestamp (mach host time)
}

protocol AudioSource: Sendable {
    var sourceType: AudioSourceType { get }
    var isAvailable: Bool { get }
    /// Emits fixed-size chunks of VadManager.chunkSize (4096) samples.
    func start() async throws -> AsyncStream<AudioChunk>
    func stop() async
}

enum AudioSourceType: String, Codable {
    case phoneMic
    case bleDevice   // future: Omi or similar BLE wearable
    case appleWatch  // future: Watch companion app
}
```

### PhoneMicAudioSource (MVP)

- Configure the shared `AVAudioSession`: category `.playAndRecord`, mode `.default`, options `[.mixWithOthers]`. `.mixWithOthers` is **required**: without it, activating the session pauses the user's Music/podcast audio ([Apple docs](https://developer.apple.com/documentation/avfaudio/avaudiosession/categoryoptions-swift.struct/mixwithothers)).
- **Built-in mic only in MVP — no Bluetooth input options.** `.allowBluetooth` is deprecated in the iOS 26 SDK (renamed `.allowBluetoothHFP`), and allowing HFP input silently reroutes capture to connected AirPods while degrading the whole route to the low-quality HFP codec. With no BT input option set, the user can listen to music on AirPods (A2DP, full quality) while the phone mic records. A future "record from AirPods" source should use iOS 26's `.bluetoothHighQualityRecording` + `.allowBluetoothHFP` as an explicit user choice.
- Start `AVAudioEngine`; install the input tap **at the hardware format** (`inputNode.outputFormat(forBus: 0)` — requesting 16 kHz directly crashes with a format mismatch), convert with `AVAudioConverter` to 16 kHz mono Float32, copy samples out of the tap buffer immediately, and emit fixed 4096-sample `AudioChunk`s.
- Note for lifespan: `installTap` is deprecated as of iOS 27 (→ `installAudioTap`). Keep all tap code inside this one class so migration is a one-file change.
- Mic permission: `AVAudioApplication.requestRecordPermission()` (the old `AVAudioSession` API is deprecated).
- Forward `AVAudioSession.interruptionNotification`, `routeChangeNotification`, and `mediaServicesWereResetNotification` to the state machine.

### Future: BLEDeviceAudioSource

Unchanged concept from v2: connect to a BLE wearable, decode Opus frames to 16 kHz mono, emit the same `AudioChunk`s. The phone still does all recording and transcription; a BLE dropout is just silence to the state machine. Adds one state — **Disconnected** (BLE source dropped, iOS audio session still healthy) — with auto-reconnect and offer-to-fall-back-to-phone-mic. Not built in MVP.

---

## State machine

Five states. v2 had four; v3 adds **Idle** (app open, not listening) and defines Stop semantics.

```
        Start tapped                                  Stop tapped (from any
┌────────┐        ┌──────────────┐                    active state): finalize
│  Idle  │───────►│  Listening    │◄──────────────┐   current segment if any,
└────────┘        │ (VAD active,  │               │   end Live Activity → Idle
    ▲             │ not recording)│               │
    │             └──────┬───────┘               │
    │                    │ .speechStart          │
    │                    ▼                        │
    │             ┌──────────────┐  .speechStart │
    │             │  Recording    │◄─────────────┤
    │             │ (writing m4a) │              │
    │             └──────┬───────┘              │
    │                    │ .speechEnd            │
    │                    ▼                        │
    │             ┌──────────────┐               │
    │             │   Silence     │── timeout ───┘
    │             │ (still writing│   expires: finalize,
    │             │  counting)    │   enqueue transcription,
    │             └──────┬───────┘   back to Listening
    │                    │
    │   audio interruption (call, Siri, …) — from Listening/Recording/Silence
    │                    ▼
    │             ┌──────────────┐
    └─────────────│ Interrupted   │── resume via Live Activity button,
      (user quits)│ (engine off)  │   notification tap, or app foreground
                  └──────────────┘
```

**Idle.** Session inactive, no orange indicator, no Live Activity. The only state where the app can be suspended without consequence.

**Listening.** Audio source streaming; every chunk goes to VAD; nothing written to disk. A 1 s ring buffer (four 256 ms chunks + slack) is continuously refilled so utterance starts aren't clipped.

**Recording.** Entered on `.speechStart`. Flush ring buffer to the writer, then append live chunks. VAD keeps running.

**Silence.** Entered on `.speechEnd`. **Audio keeps being written** — this is deliberate: if speech resumes before the timeout, the file is seamless. Cost: up to one timeout of trailing silence per segment (~0.4 MB at defaults) — acceptable; the actual last-speech timestamp is stored in metadata. If speech resumes → Recording. If the timeout expires → finalize, enqueue transcription, write .md placeholder + index entry, return to Listening.

**Interrupted.** See Interruption handling. If a segment was open (Recording/Silence), it is finalized with what exists.

**Guards (any recording state):**

- _Max segment length_ — force-finalize at 2 h and immediately continue in a new segment (ring buffer refilled from live audio). Bounds loss from any single corrupt file and keeps transcription jobs sane.
- _Min segment length_ — segments under 3 s (default) are deleted, not transcribed (VAD false-positive filter).
- _Disk guard_ — below 500 MB free: stop starting new segments, warn via notification + Live Activity.

---

## VAD configuration

Silero VAD **v6** via [`FluidInference/FluidAudio`](https://github.com/FluidInference/FluidAudio) (SPM, Apache 2.0; the converted CoreML model is MIT). Runs on the Neural Engine (`computeUnits: .cpuAndNeuralEngine`).

Real API (v2's `VADConfig(threshold:chunkSize:sampleRate:)` does not exist — verified against [VadManager source](https://github.com/FluidInference/FluidAudio/blob/main/Sources/FluidAudio/VAD/VadManager.swift) and [docs](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/VAD/GettingStarted.md)):

```swift
// VadManager is an actor. Chunk size and sample rate are fixed constants:
// VadManager.chunkSize == 4096 samples (256 ms @ 16 kHz), VadManager.sampleRate == 16_000.
let vad = try await VadManager(
    config: VadConfig(defaultThreshold: 0.6),   // library default is 0.85
    vadModel: bundledSileroModelURL              // REQUIRED: see note below
)

var state = await vad.makeStreamState()
for await chunk in audioSource.stream {
    let result = try await vad.processStreamingChunk(
        chunk.samples, state: state,
        config: .default, returnSeconds: true, timeResolution: 2)
    state = result.state
    // result.event: .speechStart / .speechEnd → drive the state machine
}
```

> [!IMPORTANT] **Bundle the VAD model.** By default FluidAudio downloads `silero-vad-unified-256ms-v6.0.0.mlmodelc` from Hugging Face on first use — a network dependency that would break the "fully on-device, works offline" promise and add a silent first-run failure mode. Ship the model in the app bundle and pass it explicitly. Also note: FluidAudio marks `VadManager` as beta — pin the package version and wrap it behind our own `SpeechDetecting` protocol so it can be swapped (e.g., for Apple's own `SpeechDetector`, which exists but currently must run coupled to a transcriber module — that coupling is why Silero was chosen).

Settings exposed to power users:

|Parameter|Default|Range|Maps to|Notes|
|:--|:--|:--|:--|:--|
|Speech threshold|0.6|0.1–0.9|`VadConfig.defaultThreshold`|FluidAudio guidance: 0.7–0.9 clean, 0.3–0.6 noisy. Library default 0.85; we start lower to favor recall, filtered by min-segment.|
|Silence timeout|45 s|15–120 s|app-level timer in Silence state|Longer merges distinct conversations; shorter splits mid-pause.|
|Ring buffer|1.0 s|0.5–3.0 s|app-level `[Float]` buffer|Worst-case detection latency ≈ 1 chunk (256 ms) + VAD min-speech confirmation (~250 ms) ≈ 0.5–0.8 s; 1 s covers it.|
|Min segment|3 s|1–10 s|app-level filter at finalize|Discards door slams, coughs, TV blips.|

VAD detection quality context: FluidAudio's published benchmark is ~96% accuracy / 97.9 F1 on a VOiCES subset at threshold 0.85 ([benchmarks](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Benchmarks.md)). (The oft-quoted "87.7% TPR @ 5% FPR" is Picovoice's measurement of upstream Silero — don't cite it as this pipeline's number.) Real-environment thresholds remain open question 2.

---

## Recording writer

AAC .m4a, 16 kHz mono, 48 kbps → ~0.36 MB/min (a 4-h speech day ≈ 86 MB). _(Implementation note 2026-07-03: the spec originally said 64 kbps, but Apple's AAC-LC encoder rejects bitrates above 48 kbps at 16 kHz mono — `kAudioCodecUnsupportedFormatError`.)_

**Crash-safety requirement:** a recorder that dies mid-file (jetsam, battery, crash) must not lose the whole segment to an unfinalized container. Acceptable implementations, developer's choice:

1. `AVAssetWriter` with `movieFragmentInterval` ≈ 10 s (fragmented output remains recoverable up to the last fragment), finalize normally at segment close; or
2. Write CAF (append-friendly, valid without finalization) during capture, remux/transcode to .m4a at finalize.

On launch, sweep for orphaned in-progress files: salvage what's readable, transcribe it, and mark the day's index with a `gap` entry (this doubles as the unclean-shutdown detector — see Failure visibility).

Files are created with Data Protection `.completeUntilFirstUserAuthentication` (`.complete` would break writes while the phone is locked).

---

## Transcription layer

Protocol unchanged in spirit from v2:

```swift
protocol TranscriptionService: Sendable {
    func transcribe(file: URL) async throws -> TranscriptionResult
}

struct TranscriptionResult: Codable, Sendable {
    let text: String
    let segments: [TranscriptionSegment]   // time-coded; speaker set only by Deepgram
    let duration: TimeInterval
    let backend: TranscriptionBackend
}

struct TranscriptionSegment: Codable, Sendable {
    let speaker: String?        // nil for on-device backends
    let text: String
    let startTime: TimeInterval
    let endTime: TimeInterval
}

enum TranscriptionBackend: String, Codable {
    case speechAnalyzer
    case deepgram
}
```

**Transcription is a persisted queue, never inline.** Segments enqueue at finalize; a serial worker drains the queue whenever the app is running (including in background while the audio engine keeps it alive). Anything left (e.g., after an interruption) drains on next resume/foreground. If a backlog must finish while the user watches (e.g., end of day), iOS 26's `BGContinuedProcessingTask` is the sanctioned way to keep working with system progress UI.

### SpeechAnalyzerService (default)

On-device, free, no API key. **No speech-recognition permission exists for this API** — no `NSSpeechRecognitionUsageDescription`, no `SFSpeechRecognizer.requestAuthorization`; file transcription needs no prompt at all (verified against Apple's sample project).

- **Preset:** v2's `.offlineTranscription` was a WWDC-beta name that never shipped. Shipping presets: `.transcription`, `.transcriptionWithAlternatives`, `.timeIndexedTranscriptionWithAlternatives`, `.progressiveTranscription`, `.timeIndexedProgressiveTranscription`. Use a custom preset built from `.transcription` plus time codes, which is what `TranscriptionSegment` needs:

```swift
let base = SpeechTranscriber.Preset.transcription
let transcriber = SpeechTranscriber(
    locale: locale,
    transcriptionOptions: base.transcriptionOptions,
    reportingOptions: base.reportingOptions,
    attributeOptions: base.attributeOptions.union([.audioTimeRange]))
```

- **Device gate:** `SpeechTranscriber` requires Apple Intelligence-class hardware, and **the app supports only those devices by design** (product decision — no `DictationTranscriber` fallback; note `SpeechTranscriber` ignores `contextualStrings` anyway, so nothing is lost). Enforce at the store level via `UIRequiredDeviceCapabilities` (see iOS requirements) and defensively at runtime: if `isAvailable == false`, show a hard unsupported-device screen — it should never appear in practice.
- **Model assets:** shared system-wide and often already present (Notes uses them), but never guaranteed. First-launch flow: check `SpeechTranscriber.installedLocales`; if missing, `AssetInventory.assetInstallationRequest(supporting:)` → `downloadAndInstall()` with progress UI; handle the offline-at-first-run error explicitly. Release unneeded locales (`release(reservedLocale:)`) — reservations are capped.
- **Memory:** the model runs outside app memory (system process) — no OOM contribution, which matters for background survival.
- **Speed expectation:** ~45x real-time measured on an M-series Mac (34-min file in 45 s); iPhone will be slower. Treat >10x as the working assumption until profiled. Characteristics otherwise as v2: no diarization (still true post-WWDC26), designed for long-form/distant audio.

### DeepgramService (optional, settings toggle)

Cloud, BYOK (user's own key, stored in **Keychain**). `POST https://api.deepgram.com/v1/listen`, body = .m4a binary (AAC/M4A are supported formats; 2 GB max, ~10-min processing cap per request).

Query params (per current docs — July 2026):

- `model=nova-3` (current best batch model; "Flux" is streaming-only)
- `diarize_model=latest` — **`diarize=true` is deprecated** (pins to the old v1 diarizer); never set both
- `utterances=true` — speaker-grouped utterances, exactly what the .md format consumes
- `smart_format=true` (includes punctuation)
- `mip_opt_out=true` — **required for the privacy story.** Deepgram's listed pay-as-you-go pricing opts requests into its Model Improvement Program (audio may be retained/used for training); opting out is the correct default for this app and must be disclosed in Settings (it can affect pricing).

Operational rules: Wi-Fi-only upload by default (toggle); persisted retry queue with exponential backoff; after N failures fall back to the on-device backend for that segment (mark `backend` accordingly). Cost ballpark for the Settings screen: ~$0.0043/min + $0.0020/min diarization (~$0.26/hr plain, ~$0.38/hr diarized). Battery note: "Deepgram saves battery vs on-device transcription" is a **hypothesis** — radio wakeups cost energy too; profile before claiming it.

### Switching behavior

Backend is a user setting; changes affect only future segments. The .md format accommodates both (below).

---

## Post-processing hook

Unchanged concept; types made `Codable` (v2's `[String: Any]` wasn't):

```swift
protocol PostProcessor: Sendable {
    func process(transcript: TranscriptionResult, audio: URL?) async throws -> PostProcessingResult
}

struct PostProcessingResult: Codable, Sendable {
    let summary: String?
    let actionItems: [String]?
    let custom: [String: String]?
}
```

Not implemented in MVP. This is where Foundation Models summarization/action-items plug in. Roadmap note: FluidAudio also ships local diarization (Pyannote/Sortformer) and ASR (Parakeet) — a future path to **on-device diarization**, which would remove the only reason Deepgram exists in this app. _(M8, 2026-07-04: implemented via Foundation Models — `PostProcessingResult` gained `title: String?`; generation is best-effort and never fails a transcription job.)_

---

## File output

```
Documents/Sotto/2026-03-14/        ← folder = LOCAL date the segment STARTED
├── 09-15-30.m4a
├── 09-15-30.md
├── 10-42-18.m4a
├── 10-42-18.md
└── _day.json                        ← index for the list view
```

- Timestamps in frontmatter are ISO 8601 **with UTC offset**; folder/day assignment uses local time; a segment spanning midnight belongs to the day it started.
- `_day.json` is written atomically (temp file + rename) after every segment, and is **rebuildable** by scanning the folder's .md frontmatter if missing/corrupt.
- The Documents directory is exposed to the Files app (`UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace`) — transcripts are the user's data; Files/Obsidian access is a feature.
- **Backup policy:** .md transcripts + `_day.json` are included in iCloud/device backup; .m4a audio is marked `isExcludedFromBackup` (bulky, and the transcript is the product). Note in onboarding.
- **Retention:** Settings offer audio retention = keep forever / delete after transcription / delete after 7 days (default: delete after transcription). Transcripts keep forever unless user deletes.

### Markdown format — SpeechAnalyzer (on-device)

```markdown
---
date: 2026-03-14T09:15:30-04:00
duration: 342
speechEnd: 2026-03-14T09:20:12-04:00
backend: speechAnalyzer
---

# Conversation — 9:15 AM

[Transcript text as a single block. No speaker attribution.]
```

### Markdown format — Deepgram

```markdown
---
date: 2026-03-14T09:15:30-04:00
duration: 342
speechEnd: 2026-03-14T09:20:12-04:00
backend: deepgram
speakers: 3
---

# Conversation — 9:15 AM

**Speaker 1:** Text from first speaker.

**Speaker 2:** Response from second speaker.
```

### Day index (`_day.json`)

```json
{
  "date": "2026-03-14",
  "segments": [
    {
      "id": "09-15-30",
      "startTime": "2026-03-14T09:15:30-04:00",
      "duration": 342,
      "backend": "speechAnalyzer",
      "hasAudio": true,
      "wordCount": 847,
      "transcriptionState": "done"
    }
  ],
  "gaps": [
    { "from": "2026-03-14T13:02:11-04:00", "reason": "uncleanShutdown" }
  ]
}
```

---

## Live Activity (core MVP feature)

A Live Activity runs whenever the app is not Idle. This is not polish — it carries three load-bearing jobs:

1. **Lock-screen pause/resume.** Buttons are wired to an [`AudioRecordingIntent`](https://developer.apple.com/documentation/appintents/audiorecordingintent) (iOS 18+) — Apple's sanctioned mechanism for starting/stopping recording from a Live Activity, and the only reliable way to restart the mic without foregrounding the app (a plain intent hits the same `cannotStartRecording` error as any background start). Apple's rule: the Live Activity must be started when recording starts and stay active while recording — which this design does anyway. This button is also the "quick-pause for sensitive moments" the legal section requires.
2. **Failure visibility.** If iOS kills the app, the Live Activity freezes/disappears — the user can see listening died instead of discovering a blank afternoon at 9 pm.
3. **Review compliance.** Guideline 2.5.14 requires "a clear visual and/or audible indication when recording"; documented rejections show reviewers want it persistent and non-dismissable. Orange system dot + permanent Live Activity is the strongest available answer.

Content spec — lock screen & Dynamic Island (expanded): state label (Listening / Recording / Paused — call / Paused by you), elapsed listening time, today's conversation count, Pause/Resume button. Dynamic Island (compact): state glyph + count. Update on every state transition; no timers ticking faster than the system allows for Live Activity updates.

---

## Interruption handling

Register for `interruptionNotification`, `routeChangeNotification`, and `mediaServicesWereResetNotification` right after session configuration.

**On `.began`** (phone call, FaceTime, Siri — iOS has already stopped the engine):

1. Wrap the handler in `beginBackgroundTask` — after audio stops, the app has roughly **30 seconds** before suspension.
2. Transition to Interrupted; if a segment was open, finalize the .m4a **only** (fast). Do **not** transcribe inline — enqueue it (v2 transcribed here; a long segment cannot finish in the window).
3. Update the Live Activity to "Paused — call" with a Resume button.
4. **Schedule the fallback local notification now** ("Sotto was paused. Tap to resume."), not on `.ended` — Apple documents that a `.began` is **not guaranteed** to get a matching `.ended`. Dedupe/cancel it if resume happens first.
5. End the background task.

**On `.ended`** (when it does arrive):

- App foregrounded: reconfigure session, restart engine, → Listening, clear notification.
- App backgrounded: do **not** call `engine.start()` directly — it fails with error 561145187 (`AVAudioSession.ErrorCode.cannotStartRecording`; Apple-engineer-confirmed). Recovery paths, in order: user taps Live Activity **Resume** (`AudioRecordingIntent` — sanctioned background start), user taps the notification (foregrounds the app), or user opens the app.

**Route changes** (`.oldDeviceUnavailable`, e.g., wired mic unplugged): rebuild the tap for the new hardware format, continue.

**`mediaServicesWereResetNotification`:** full teardown and rebuild of session + engine + tap.

**Unclean shutdown detection:** on every transition, persist a tiny heartbeat state file (`state`, `timestamp`). On launch: heartbeat says "listening" but we're cold-starting → the app died; salvage orphaned audio, record a `gap` in `_day.json`, and show a one-line banner ("Listening stopped unexpectedly at 1:02 PM").

---

## Battery expectations

> [!IMPORTANT] **iPhone Air is the required support target, and it sets the power budget.** At 3,149 mAh (~12.1 Wh) it has the smallest battery in the lineup, so the design must close on the Air, not on a Pro Max. Provisional budget: **average total draw ≤ 0.35–0.4 W** while listening, so a 16-h waking day fits alongside normal phone use. The Air's thin chassis also has the least thermal headroom — keep transcription bursts chunked and back off when `ProcessInfo.thermalState` reaches `.serious`.

> [!NOTE] All figures are estimates and the v2 table did not reconcile with itself (its component sum ~200–350 mW implies 36–63 h on a 12.7 Wh battery, not the 10–14 h it listed). Treat everything below as **low-confidence until profiled with Instruments on an actual iPhone Air** (M0 battery spike is the gate). No published power figures exist for FluidAudio VAD.

|Component|Estimated draw|
|:--|:--|
|Mic + audio engine tap (16 kHz mono)|~30–50 mW|
|Silero VAD on ANE (~4 inferences/sec — 256 ms chunks, not v2's 31/sec)|~30–80 mW|
|AAC encoding during speech|~30–50 mW burst|
|SpeechAnalyzer transcription at segment close|~200–500 mW burst|
|iOS baseline while app held awake|~100–300 mW|

Implied continuous draw ~0.2–0.5 W, but real-world all-day figures (CPU wakeups 4×/sec, radios, thermals) plausibly land higher.

|Device|Battery|If draw = 0.35 W|If draw = 1 W|
|:--|:--|:--|:--|
|**iPhone Air (required target)**|3,149 mAh (~12.1 Wh)|~35 h|~12 h|
|iPhone 15 Pro|12.70 Wh|~36 h|~13 h|
|iPhone 17 Pro|4,252 mAh (~16.4 Wh)|~47 h|~16 h|
|iPhone 17 Pro Max|5,088 mAh (~19.6 Wh)|~56 h|~20 h|

Reading the table: if the pipeline lands near the 0.35 W budget, the Air comfortably survives a full day even with normal use on top; if it creeps toward 1 W, the Air fails the product promise while a Pro Max still limps through — which is exactly why profiling happens on the Air. **Primary test device: iPhone Air; keep a 17 Pro Max as the comparison point.** All supported devices are Apple Intelligence-class, so `SpeechTranscriber` is always available. Detect Low Power Mode (`ProcessInfo.isLowPowerModeEnabled`) and surface a warning — throttling may degrade VAD timeliness.

---

## App Store strategy

Target: App Store distribution. **Honest risk framing:** guideline 2.5.4 permits background modes "only … for their intended purposes: VoIP, audio playback, location, task completion, local notifications, etc." — background _recording_ rides on the OS entitlement's documented behavior, not an explicit guideline blessing, and a 16-h/day mostly-silent session invites an "intended purpose" question. There is **no known approved all-day phone-mic ambient recorder**: Bee (Amazon), Limitless (Meta), Plaud, and Omi all record on wearables or Apple Watch; Otter and Just Press Record are user-initiated sessions with background continuation. That makes this app a test case — hence milestone M7.

> [!NOTE] **Positioning (adopted 2026-07-04): "AI notetaker that starts itself — auto-detects your meetings."** The observed app behavior is a user-initiated session with background continuation (the already-approved Otter/Just Press Record pattern); "all-day" is a user choice, not app behavior. Store metadata, review notes, and onboarding copy use the meeting-notetaker frame. Marketing must never say "records everything all day."

**Review preparation:**

- Development is deliberately local-first: dev builds and TestFlight **internal** testing involve no Apple review at all, so the full app can be built and lived-with before Apple ever sees it. The first contact is M7 — a minimal-footprint submission (or TestFlight **external** / Beta App Review) once the core loop is proven and before launch spend.
- App Store description states plainly that the app records audio in the background after the user starts it.
- App Review Information notes: user-initiated; persistent Live Activity + system orange mic indicator always visible; all processing on-device by default; automatic stop on phone calls; quick pause control.
- Prominent Start/Stop; onboarding explains the orange indicator, battery, and recording-law responsibility (2.5.14: "explicit user consent and … clear visual and/or audible indication when recording" — verbatim requirement).
- Privacy nutrition labels: default config collects nothing off-device; if the user enables Deepgram, audio goes to a third party under the user's own account — disclose in the privacy policy; policy URL in the listing.
- 5.1.2(i) (no use of someone's personal data without permission) is the guideline a reviewer would reach for regarding bystanders — the onboarding consent-law screen and "transparency tool, not a spy tool" positioning are the mitigation. Never market secrecy.
- Consider submitting from an LLC rather than a personal account (5.1.1(ix) expects apps handling sensitive data to come from a legal entity; cheap CT LLC also useful for liability).

---

## Legal considerations

_(Engineering-relevant summary; not legal advice.)_

**Federal:** 18 U.S.C. § 2511(2)(d) — one-party consent; as a participant, the user satisfies it (unless recording to further a crime/tort). Verified.

**Connecticut (home state):** hybrid — verified against current statutes:

- In-person conversations: effectively **one-party** for criminal law. §§ 53a-187/189 criminalize "mechanical overhearing" only when done "by a person **not present** thereat" without a party's consent — recording conversations you're part of is not eavesdropping. Class D felony applies to recording conversations you're _not_ present at (don't leave the phone recording in a room you leave — worth a line in onboarding).
- Phone calls: **all-party consent, civil liability** (§ 52-570d, private telephonic communications; damages + attorney's fees). Architecturally handled: a call interrupts the audio session and the app stops capturing before call audio exists (Interrupted state). Keep this behavior — it is a legal control, not just a technical limitation.

**Travel:** ~11 states require all-party consent (CA, FL, MD, MA, NH, PA, WA, IL, MT, and arguably DE/MI), and **Oregon requires all-party consent for in-person conversations specifically**. The app is location-agnostic; responsibility shifts to the user via: onboarding disclaimer + link to a 50-state summary (e.g., Justia's survey), the Live Activity quick-pause, and no "stealth" positioning.

---

## Build plan (MVP scope)

**M0 — Local validation spikes (before committing to full build; no store contact):**

- a. _Pocket audio:_ record 5–10 real conversations, phone in pocket, via Voice Memos; run through a SpeechAnalyzer demo. Gate: ≥ ~80% usable, or pivot to guided body-worn placement.
- b. _Battery floor:_ engine + VAD only, 8 h, Instruments, **measured on an iPhone Air**. Gate: implied drain fits the ≤ 0.35–0.4 W budget.
- c. _Interruption drill:_ background the prototype, trigger calls/FaceTime/Siri; verify `.began` handling, notification delivery, and Live Activity resume path.

**M1 — Audio + VAD pipeline:** `AudioSource` protocol, `PhoneMicAudioSource` (hardware-format tap → converter → `AudioChunk`s), session config `[.mixWithOthers]`, bundled Silero model, `VadManager` streaming events, ring buffer.

**M2 — State machine + writer:** five states + guards, crash-safe .m4a writer, heartbeat/unclean-shutdown detection, Stop semantics.

**M3 — Live Activity + interruptions:** Live Activity with `AudioRecordingIntent` pause/resume, `.began`/`.ended` flows, fallback notification (+ `UNUserNotificationCenter` authorization), route change + media-services-reset handling.

**M4 — Transcription:** persisted queue; `SpeechAnalyzerService` (custom preset + `.audioTimeRange`, asset download flow, unsupported-device guard); `DeepgramService` (params above, Keychain, Wi-Fi-only default, retry queue, on-device fallback).

**M5 — Files:** date folders, .m4a/.md pairs, atomic `_day.json` + rebuild, retention policy, backup exclusions, Files-app exposure, disk guard.

**M6 — UI:** the five screens + onboarding below.

**M7 — App Review probe + launch prep:** everything through M6 needs no Apple review — develop and test with dev provisioning and TestFlight **internal** (up to 100 testers, no Beta App Review). When the core loop is proven locally and before any launch spend: submit a minimal-footprint build (or go via TestFlight **external**, which triggers the lighter Beta App Review) to surface the always-on question. A rejection with feedback at M7 is cheap; after marketing, expensive.

---

## UI specification

Design language: stock SwiftUI, system colors/typography (supports the "transparency tool" review posture). Every screen must render sensibly in Dark Mode and at accessibility text sizes. No third-party UI dependencies.

### 1. Main screen

- **Purpose:** one glance = current state; one tap = start/stop.
- **Layout:** large state dial/indicator (Idle / Listening / Recording / Paused — call / Paused) with subtle animation while listening; primary Start/Stop button; today's summary line ("6 conversations · 47 min"); tap summary → List view. ~~Battery-impact hint shown while active~~ _(removed 2026-07-04, product decision: don't surface battery in UI)_.
- **States:** _Idle_ (Start prominent); _active_ (Stop + state label + elapsed); _mic permission denied_ (inline explainer + "Open Settings" deep link — Start disabled); _model downloading_ (progress inline; Start stays ENABLED — recordings queue safely and are transcribed once the model is ready. Copy: "Preparing on-device transcription — recordings are saved and will be transcribed when it's ready." Amended 2026-07-04 per M6a review adjudication.); _disk guard tripped_ (warning banner); _post-crash_ (one-line gap banner, dismissible).
- **Edge:** Stop while Recording/Silence → finalize current segment first, then Idle (show brief "Saving…" state).

### 2. List view (Today / history)

- **Purpose:** browse a day's conversations.
- **Layout:** date navigator (default Today, back/forward, calendar picker); rows from `_day.json`: start time, duration, word count, backend glyph (on-device/cloud), 2-line transcript preview; `transcriptionState == queued` rows show a spinner + "Transcribing…", `failed` rows show retry affordance. Gap markers ("Listening was off 1:02–3:15 PM") render between rows.
- **States:** empty-today (friendly "Nothing recorded yet — Sotto is listening" vs "Start listening to capture your first conversation" depending on state); empty-history date; index missing → rebuild from files with progress toast.
- **Actions:** swipe-delete (confirm; deletes .m4a + .md + index entry); share sheet per row (.md, and .m4a if retained).

### 3. Detail view

- **Purpose:** read one conversation; verify against audio.
- **Layout:** title = time + duration; metadata row (backend, word count, speakers if diarized); full transcript — Deepgram version renders speaker turns as paragraphs with bold labels; audio player (scrubber, ±15 s, playback speed) shown only if audio retained. Playback must not disturb the live pipeline (playback through the same `.playAndRecord` session; pause Listening is _not_ required).
- **Actions:** share/export .md; copy text; delete (confirm); "Re-transcribe with current backend" (replaces .md, keeps audio) — enabled only when audio exists.
- **States:** transcription pending (audio playable, text area shows progress); transcription failed (error + retry); audio deleted (text-only, player hidden).

### 4. Settings

- **Listening:** audio source (Phone mic — sole option, picker prewired for future sources); VAD threshold slider (0.1–0.9, labeled Sensitive ↔ Strict, "reset to default"); silence timeout; ring buffer; min segment. Power-user block collapsed by default.
- **Transcription:** backend toggle (On-device / Deepgram). On-device row shows speech-model status (installed / download button with size). Deepgram block: API key field (SecureField → Keychain; "Test key" button hits a 1 s sample), Wi-Fi-only toggle (default on), cost note (~$0.26/hr; ~$0.38/hr with diarization), privacy note ("Audio is sent to Deepgram under your account; training opt-out is always sent").
- **Storage:** audio retention (delete after transcription ▸ default / keep 7 days / keep forever); storage-used readout per category; "Open in Files" link.
- **Notifications:** status + link to system settings.
- **About/Legal:** recording-law summary + 50-state link, privacy policy, licenses (FluidAudio Apache-2.0, Silero CoreML MIT).

### 5. Onboarding (first launch, 4 cards + 2 system prompts)

1. _What it does_ — listens all day, records only speech, everything stays on your phone. _(copy updated 2026-07-04 to the meeting-notetaker frame: "Your notetaker that starts itself.")_
2. _What you'll see_ — orange mic indicator + Live Activity are always visible while listening; ~~battery expectation ("roughly comparable to music playback; heavy days may need a top-up")~~ _(removed 2026-07-04, product decision: don't surface battery in UI)_.
3. _Your responsibility_ — one-party vs all-party consent in plain words; CT phone-call rule handled automatically (calls stop recording); "laws differ by state" + link. Require an explicit "I understand" tap.
4. _Permissions_ — mic prompt (`AVAudioApplication.requestRecordPermission`), then notification prompt (or `.provisional` silently — dev choice, document it).
5. If needed: speech-model download card with progress before first Start. (No speech-recognition permission exists — do not add one.)

### Live Activity / Dynamic Island

Specified above under Live Activity — treat as a first-class screen in design review.

---

## Dependencies

|Package|Source|License|Purpose|Notes|
|:--|:--|:--|:--|:--|
|FluidAudio|`FluidInference/FluidAudio` (SPM)|Apache 2.0|Silero VAD v6 via CoreML|Pin exact version (`VadManager` is marked beta); bundle `silero-vad-unified-256ms-v6.0.0.mlmodelc` (MIT) — no runtime HF download|
|Speech framework|Apple (system)|—|SpeechTranscriber / AssetInventory|iOS 26 API surface|
|ActivityKit + AppIntents|Apple (system)|—|Live Activity + `AudioRecordingIntent`||

Deepgram via `URLSession` — no SDK. No other third-party code.

---

## iOS requirements

- **Target:** iOS 26. (Watch for iOS 27: `installTap` → `installAudioTap` migration; new Speech input-plumbing classes could replace hand-rolled tap/convert code later.)
- **Devices:** **Apple Intelligence-class only** (iPhone 15 Pro and later — includes iPhone Air, the required support target). Gate at the store level via `UIRequiredDeviceCapabilities` = `iphone-performance-gaming-tier` (Apple defines it as "equivalent to iPhone 15 Pro," iOS 17+ — it approximates the Apple Intelligence set; validate the exact device list before shipping) and defensively at runtime via `SpeechTranscriber.isAvailable` with a hard unsupported-device screen.
- **Entitlements/Info.plist:** `UIBackgroundModes: [audio]`; `NSMicrophoneUsageDescription`; `NSSupportsLiveActivities: YES`; `UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace`. **No** `NSSpeechRecognitionUsageDescription` (not used by SpeechAnalyzer).
- **Audio session:** `.playAndRecord`, mode `.default`, options `[.mixWithOthers]`.
- **Concurrency:** Swift 6 strict concurrency; state machine as an actor; UI via `@Observable`.
- **Distribution:** App Store (see M0); consider LLC as the seller entity.

---

## Naming

The app is named **Sotto** (decided 2026-07-03; _sotto voce_ — short, elegant, ownable). Full App Store search + USPTO knock-out still required before store assets are made (open question 7).

Ruled out by collision checks (run 2026-07-03): **Earshot** (3+ live iOS apps), **Murmur** (crowded — two on-device voice-to-text apps), **Anecdote** (live wellness companion), **Recall** (Microsoft feature), anything Whisper-adjacent (OpenAI model + secrecy optics). Other candidates considered: Offhand, Retell, Remark, Palaver, Aside.

---

## Open questions for validation

1. **Pocket audio quality** (unchanged, still premise-level): 5–10 real pocket recordings through SpeechAnalyzer; <~80% usable → rethink placement guidance or premise.
2. **VAD threshold in real environments:** benchmark FluidAudio VAD (coffee shop, car, office, street) around defaults 0.5–0.7; decide single compromise value vs environment presets. Note the library's own default is 0.85.
3. **Interruption recovery drill:** verify `.began` → notification & Live Activity flow with phone calls, FaceTime, Siri; measure how often `.ended` never arrives; confirm `AudioRecordingIntent` resume works reliably from the lock screen while backgrounded.
4. **Speech-model presence:** on fresh iOS 26 hardware, is the English model already installed (`SpeechTranscriber.installedLocales`)? Sizes the first-run download UX.
5. **Battery profiling:** M0b above, on an iPhone Air; also compare SpeechAnalyzer-burst vs Deepgram-upload energy before making any battery claims in marketing.
6. **App Review probe:** M7 — the project's biggest external risk, deliberately placed after local development and before launch spend.
7. **Name knock-out:** full App Store search + USPTO knock-out for "Sotto" before any store assets are made.
8. **Store device gating:** confirm `iphone-performance-gaming-tier` excludes exactly the intended devices (and nothing more) on current hardware.

---

## Architecture

```
┌────────────────────────────────────────────────────────────────┐
│                            Sotto                               │
│                                                                │
│  AudioSource (protocol) ── PhoneMicAudioSource (MVP)            │
│   │   AVAudioEngine tap @ hw format → AVAudioConverter          │
│   │   [future: BLEDeviceSource (Opus→PCM), WatchSource]         │
│   ▼ AsyncStream<AudioChunk> ([Float] 4096 @16 kHz)              │
│  VadManager (FluidAudio actor, Silero v6, ANE, bundled model)   │
│   ▼ .speechStart / .speechEnd events                            │
│  RecorderStateMachine (actor)                                   │
│   states: Idle ▸ Listening ▸ Recording ▸ Silence ▸ Interrupted  │
│   guards: max 2 h ▸ min 3 s ▸ disk ▸ heartbeat file             │
│   ├─► RingBuffer (1 s, [Float])                                 │
│   ├─► CrashSafeAudioWriter (.m4a fragmented / CAF→remux)        │
│   ├─► LiveActivityController (state, pause/resume via           │
│   │      AudioRecordingIntent; failure visibility)              │
│   └─► InterruptionHandler (.began: finalize+notify ≤30 s;       │
│          .ended: fg-restart only; route/media-reset)            │
│  TranscriptionQueue (persisted, serial)                         │
│   ├─ SpeechAnalyzerService (SpeechTranscriber; app targets      │
│   │     Apple Intelligence-class devices only)                  │
│   └─ DeepgramService (BYOK, nova-3, diarize_model=latest,       │
│         utterances, mip_opt_out, Wi-Fi-only, retry→fallback)    │
│  FileStore (day folders, .m4a+.md, atomic _day.json+gaps,       │
│      retention, backup rules, Files-app exposure)               │
│  PostProcessor (protocol only in MVP; future: Foundation        │
│      Models summaries, FluidAudio on-device diarization)        │
└────────────────────────────────────────────────────────────────┘
```

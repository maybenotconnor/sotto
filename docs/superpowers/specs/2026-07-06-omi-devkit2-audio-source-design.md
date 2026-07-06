# M12 — Omi Devkit 2 Audio Source — Design

**Date:** 2026-07-06
**Status:** Approved design (sections 1–2 user-approved interactively; sections 3–4 approved via "continue autonomously")

## Summary

Support the Omi Devkit 2 — a BLE wearable microphone pendant — as an audio input device for Sotto. When an Omi is paired, Sotto prefers it whenever it is connected and automatically falls back to the phone mic when it is not, so all-day coverage never silently stops. Everything downstream of the `AudioSource` seam (VAD, recorder state machine, writer, transcription, files) is unchanged.

This fills the seam the spec designed for on day one: `docs/SPEC.md` §"Audio source layer" (protocol dealing in `AudioChunk` value types, `AudioSourceType.bleDevice` sketched as "future: Omi or similar BLE wearable").

## User decisions (2026-07-06)

1. **Dropout policy:** full auto-fallback to phone mic in this epic (not phased, not tap-to-fallback). Driving requirement: *never lose recordings unknowingly*.
2. **Selection model:** auto-prefer paired Omi. No source picker; if an Omi is paired it is used whenever connected, phone mic otherwise. Settings only pairs/forgets.
3. **Device scope:** live audio streaming + battery level. **Out of scope:** offline/8 GB storage sync, device button actions, speaker, and all other Omi services (accelerometer, image, time sync).
4. **Test hardware:** Devkit 2 ordered, not yet on hand. Build against fakes and the documented protocol; stage real-device verification at the end.
5. **Integration approach:** vendor the narrow decode pieces from the MIT omi repo (`Codecs.swift`, `PacketCounter.swift`, with attribution), add the `swift-opus` SPM dependency, and write our own CoreBluetooth layer. Do **not** depend on the full `omi-lib` SDK (drags in SwiftWhisper + AudioKit, singleton design, fragile name-based discovery) and do **not** clean-room the solved byte-level problems.

## Device & protocol facts (researched 2026-07-06, from BasedHardware/omi source)

- **Hardware:** Seeed XIAO nRF52840 Sense (not nRF5340 — that's the Omi CV1), dual PDM mics, ~150 mAh (~10–14 h), programmable button, 8 GB flash, speaker.
- **Audio GATT:** service `19B10000-E8F2-537E-4F6C-D104768A1214`; audio data (notify) `19B10001-…`; codec type (read) `19B10002-…`.
- **Battery:** standard service `180F`, level char `2A19` (notify on newer firmware; poll on older).
- **Device info:** standard `180A` (firmware revision `2A26` shown in Settings).
- **Packet framing:** every notification = `[uint16 LE packet# | uint8 fragment index | payload]`. Packet# is a rolling counter wrapping 0xFFFF→0x0000. A codec frame larger than one notification spans notifications sharing a packet# with incrementing fragment index; reassemble until packet# changes.
- **Codec values (char 19B10002):** 0 = PCM16/16 kHz, 1 = PCM16/8 kHz, 10 = µ-law/16 kHz, 11 = µ-law/8 kHz, **20 = Opus/16 kHz mono @ 32 kbps** (default on firmware ≥1.0.3). Opus encoder runs `RESTRICTED_LOWDELAY`, complexity 3, **FEC/DTX disabled** — the decoder must invoke packet-loss concealment (null-pointer decode) on detected sequence gaps. Frame size is 10–20 ms (docs and firmware config disagree; Opus TOC is self-describing, so decode handles either — confirm on hardware).
- **iOS constraints:** CoreBluetooth negotiates MTU and connection interval itself (firmware's 498-byte / 7.5 ms preferences are not obtainable); payload per notification = MTU − 3.
- **License:** entire repo MIT ("Based Hardware Contributors"); swift-opus/libopus BSD-3. Vendoring is fine with attribution headers.
- **Opus on Apple platforms:** no system support (AVAudioConverter cannot decode Opus). Use `nelcea/swift-opus` (what omi-lib uses; pin the revision omi pins for parity).

## Architecture

New layer folder `Sotto/Omi/`. All downstream components unchanged.

```
CoreBluetoothOmiTransport (actor, owns CBCentralManager)
    │  raw BLE notifications + connection/battery events
OmiFrameAssembler (pure struct; vendored PacketCounter logic)
    │  codec frames + gap signals
OmiAudioDecoder (vendored Codecs.swift; swift-opus; PLC on gaps)
    │  [Float] 16 kHz mono
SampleChunker (REUSED from Sotto/Audio/)
    │  4096-sample AudioChunks (256 ms)
OmiAudioSource : AudioSource (actor, composes the above)
    │
FailoverAudioSource : AudioSource (actor)
    owns OmiAudioSource + PhoneMicAudioSource, presents ONE
    AsyncStream<AudioChunk>, swaps active source, emits source events
    │
ListeningPipeline → VAD → RecorderStateMachine → writer → … (unchanged)
```

### Components

- **`OmiTransport` (protocol)** — the hardware quarantine seam. API (async/AsyncStream): scan for service UUID, connect(identifier), disconnect, read codec, subscribe audio notifications, battery reads/notifications, connection-state events. Implemented by `CoreBluetoothOmiTransport` (actor wrapping `CBCentralManager` + delegate plumbing, scan filtered to `19B10000-…`, state restoration identifier set). A `FakeOmiTransport` drives all automated tests.
- **`OmiFrameAssembler`** — pure transform: notification bytes → complete codec frames; validates the uint16 sequence with wraparound; reports gaps (count of missing packets) as explicit signals. Adapted from omi-lib's `PacketCounter.swift` (MIT attribution header).
- **`OmiAudioDecoder`** — codec value → concrete decoder (Opus via swift-opus, PCM16, µ-law); frames → `[Float]` 16 kHz mono; on a gap signal performs one PLC decode per missing frame to avoid clicks. Adapted from omi-lib's `Codecs.swift` (MIT attribution header). Unknown codec value → typed error (no stream).
- **`OmiAudioSource : AudioSource`** — actor composing transport → assembler → decoder → `SampleChunker`; emits `AsyncStream<AudioChunk>`; exposes a connection-state stream (disconnected / connecting / connected / streaming) and battery level. Honors the documented `stop()` contract (idempotent, always finishes the continuation).
- **`FailoverAudioSource : AudioSource`** — actor owning both sources; presents one chunk stream; runs the failover state machine below; emits source-change events consumed by `ListeningPipeline` (segment boundary) and `AppModel` (UI/notifications).
- **`OmiDeviceStore`** — persists the single paired peripheral (identifier UUID + display name) in UserDefaults. Pair/forget only.
- **Composition:** `AppModel.performSetUp()` (today's single `PhoneMicAudioSource()` construction site) branches: Omi paired → `FailoverAudioSource(omi:phoneMic:)`; else → `PhoneMicAudioSource()` exactly as today. Zero behavior change for users without an Omi.
- **`AudioSourceType`** re-widened: `{ phoneMic, omi }`.

### Project configuration (`project.yml`, then `xcodegen generate`)

- `UIBackgroundModes` += `bluetooth-central` (alongside existing `audio`).
- `NSBluetoothAlwaysUsageDescription` added.
- SPM: add `swift-opus` (pinned to the revision omi-lib pins). FluidAudio remains the only other third-party dependency.

## Connection lifecycle & failover

**Pairing (one-time):** Settings → scan sheet listing peripherals advertising the audio service (never name-matching — survives the Friend→Omi rebrand; service-UUID filters are also required for background scanning). Tap to connect; store identifier; read codec + firmware revision.

**Session start:** `FailoverAudioSource.start()` issues the Omi connect and starts a ~3 s race; if the Omi isn't streaming by then, capture begins on the phone mic immediately (coverage never waits on the pendant). When the Omi comes up it switches over.

**Failover state machine** (recorder's five states untouched):

| Omi state | Active capture | Transition |
|---|---|---|
| streaming | Omi | `didDisconnect` → reconnecting |
| reconnecting (grace ≤ 3 s) | none (silence) | reconnects within grace → streaming (no segment churn); grace expires → fallback |
| fallback | phone mic | Omi streaming stably ≥ 10 s (hysteresis) → switch back to Omi |
| unavailable (mic start also failed) | none | loud notification + Live Activity error state |

- **Segment boundary rule:** every source switch finalizes the open segment (crash-safe CAF closes cleanly) and listening resumes on the new source. No mixed-source audio files. The grace window loses no audio (a disconnected Omi delivers nothing) — it only prevents a radio blip from splitting a conversation.
- **Asymmetric thresholds** (3 s out, 10 s back) are flap damping; both are named constants with tests.
- **Reconnect:** on disconnect, immediately re-issue `connect()` to the known peripheral — CoreBluetooth holds the request pending indefinitely and completes it when the device reappears; no scan loop.
- **Background execution:** while the Omi streams, `bluetooth-central` services the app per notification; on fallback, the existing `audio` mode applies. **Spike S1 (first implementation task, iPhone-only):** verify the mic can be activated from the background off a BLE-disconnect wakeup with no user tap. If iOS refuses, fallback degrades to an actionable notification ("Omi disconnected — tap to switch to phone mic") and the design records that as the accepted degradation.
- **Stretch — CoreBluetooth state restoration (Spike S2):** with a restoration identifier, iOS can relaunch the app after a background kill when the Omi sends data — recovering a failure mode that is unrecoverable in phone-mic mode (SPEC platform reality #2). In scope as a stretch task gated on the spike; the epic does not depend on it.
- **Battery:** subscribe to `2A19` (poll fallback on old firmware); Settings shows the level; a local notification fires once when it crosses ~15% ("Omi battery low").

## UI & surfacing

- **Settings — "Omi Device" group.** Unpaired: a "Pair Omi Device" row opening the scan sheet. Paired: device name, live status (Connected/Streaming/Disconnected), battery %, firmware revision, and a confirmed destructive "Forget This Device". (M10's engine-picker section is the structural template.)
- **Home header:** the status label carries the source ("Listening · Omi" / "Listening · iPhone mic"); the Disconnected/waiting state is visible while on fallback.
- **Live Activity:** content state gains the active source; disconnect/fallback is reflected so the lock screen never claims Omi capture while on the phone mic.
- **Notifications:** (1) fallback engaged — "Omi disconnected — continuing on iPhone mic" (pocket-muffled audio must never be a surprise); (2) low battery; (3) unavailable — "Recording stopped" loud alert. Grace + hysteresis inherently throttle flapping spam.
- **Bluetooth off / unauthorized:** reuse the existing banner pattern (as with micDenied) — "Bluetooth is off — Omi unavailable" with an Open Settings action; capture continues on phone mic.

## Data model

- `FinalizedSegment` and `DayIndexEntry` gain `source: AudioSourceType` (decoded default `.phoneMic` so existing `_day.json` files and old `.md` frontmatter remain valid).
- Markdown frontmatter gains `source: omi|phoneMic`; `DayIndexRebuilder` reads it back.
- Conversation detail view shows the source. No filtering UI (YAGNI).
- No new gap semantics: source switches split segments but coverage continues; `gaps[]` remains for genuine coverage loss.

## Error handling

| Failure | Handling |
|---|---|
| Unknown codec value | Typed error; no stream; Settings shows "unsupported firmware codec" with the value |
| Sequence gap | Assembler reports gap count → decoder runs PLC per missing frame; dropout counter exposed on the source snapshot for diagnostics |
| Opus decode error | Skip frame, log; N consecutive failures → treat as transport fault → disconnect/reconnect cycle |
| BLE disconnect | Failover state machine (above) |
| Bluetooth off / unauthorized | Banner + phone-mic capture; Omi treated as disconnected |
| Phone mic fails during fallback | `unavailable` state → loud notification |
| App killed in background | Live Activity goes stale (existing signal); stretch: state restoration relaunch |

## Testing

All automated tests run without hardware; `FakeOmiTransport` is the root fake.

- **`OmiFrameAssembler`:** golden byte-fixture tests — single-notification frames, multi-fragment reassembly, packet# wraparound at 0xFFFF, gap detection, varying MTU payload sizes.
- **`OmiAudioDecoder`:** round-trip fixtures (encode a known waveform with swift-opus in the test, decode, compare); PCM16 and µ-law paths; PLC invoked on gap signals; unknown-codec error.
- **`OmiAudioSource`:** fake transport → packets in, `AudioChunk`s out; connection-state transitions; `stop()` contract (idempotent, finishes continuation, safe when never started).
- **`FailoverAudioSource`:** fake sources — start race, grace-window reconnect (no switch), grace expiry (switch + event), hysteresis on return, flap sequences, `stop()` contract, single-stream continuity across swaps.
- **Integration:** fake transport → full pipeline → segments finalize with correct `source` labels and close at switch boundaries.
- **Existing suites:** `AudioSourceType` widening and snapshot/index field additions keep all current tests green (defaulted fields).
- **Hardware verification checklist (end-stage, when the Devkit arrives):** pairing; live streaming quality; walk-away disconnect → fallback → return → switch-back; overnight background session; battery reporting + low-battery notification; Spike S1 confirmation; state restoration behavior; codec value on the shipped firmware.

## Risks

1. **Background mic activation on BLE disconnect (Spike S1)** — the only load-bearing unknown; has an acceptable documented degradation.
2. **Firmware drift** — framing/UUIDs owned by us once vendored; historically stable; codec char read at connect defends against codec changes.
3. **iOS BLE throughput** — 32 kbps Opus at MTU−3 payloads is well within CoreBluetooth norms; frame-size ambiguity (10 vs 20 ms) is absorbed by Opus TOC self-description.
4. **App Review** — `bluetooth-central` + mic is a common accessory pattern; no new review surface beyond the existing all-day-recording posture.

## Attribution

`Sotto/Omi/Vendored/` files carry MIT headers crediting "Based Hardware Contributors" (github.com/BasedHardware/omi, `sdks/swift`). swift-opus (BSD-3) added via SPM, pinned.

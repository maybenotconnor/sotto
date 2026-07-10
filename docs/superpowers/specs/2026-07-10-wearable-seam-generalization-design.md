# Wearable Seam Generalization — Design

Date: 2026-07-10
Status: approved

## Summary

Generalize the Omi-specific audio-source seam into a device-agnostic wearable
architecture, without adding any new device support. Pure refactor: after this work
the app behaves identically, existing pairings and persisted data survive untouched,
and adding a future device family (e.g. Limitless Pendant) becomes "write a new
device module ending in a `WearableAudioSource`, add a `DeviceKind` case" instead of
a cross-cutting rename.

Motivating analysis (2026-07-10): everything downstream of `AudioChunk` is already
device-agnostic; the leaks are naming (`OmiConnectionState` used by generic code),
the pairing store's Omi-only shape, AppModel's concrete `OmiAudioSource` reach-in for
battery/setup-failure observation, and hardcoded UI copy.

## User decisions (2026-07-10)

- **Full generalization**: rename everything generic code touches, including
  AppModel's observable properties and matching test renames. Not seam-contracts-only.
- **Kind-driven UI copy**: a `DeviceKind` enum carries display copy; users still see
  "Omi Device" / "Pair Omi Device…" today because `.omi` is the only kind. No generic
  "Wearable" copy in the UI.
- No new device support in this change. Limitless explicitly out of scope.

## Invariants (what cannot change)

- **Zero behavior change.** Failover timing (startup race / grace / hysteresis), the
  recorder state machine, the Omi BLE protocol code, and all pipeline stages are
  untouched. Existing behavioral tests pass with renames only.
- **Zero data migration.** Persisted surfaces are frozen:
  - `AudioSourceType` raw values `"omi"` / `"phoneMic"` — persisted in day-index
    entries (`DayIndex`), transcript frontmatter `source:` lines
    (`TranscriptMarkdownWriter`), and transcription-queue job records
    (`TranscriptionQueue`).
  - UserDefaults key `"pairedOmiDevice"` — kept verbatim so existing pairings
    survive; only the decoded struct gains an optional field (see Data model).
- `Info.plist` `NSBluetoothAlwaysUsageDescription` keeps naming Omi (accurate today;
  revisit only when a second device ships).

## Architecture

The extension point is **one `WearableAudioSource` implementation per device
family**, not a universal transport. Transports stay device-internal and
device-shaped: `OmiTransport`'s `connected(codecValue: UInt8)` event encodes OMI's
codec-characteristic handshake, and handshakes don't share a shape across vendors —
forcing one transport protocol to fit every device would repeat that leak at the
generic layer. The portable boundary is "decoded 16 kHz mono Float32 chunks +
connection lifecycle".

Two protocols at the seam, on purpose:

- `ConnectableAudioSource` (exists, unchanged in shape): `AudioSource` +
  `connectionStates()`. What `FailoverAudioSource` needs.
- `WearableAudioSource` (new): `ConnectableAudioSource` + `batteryLevels()` +
  `latestBatteryLevel` + `setupFailureMessage`. What AppModel's Settings observation
  needs. Collapsing the two would force failover to depend on battery APIs it never
  uses.

### New types

```swift
/// Catalog of pairable wearable families. All user-facing copy renders from this.
enum DeviceKind: String, Codable, Sendable {
    case omi
    var displayName: String { … }           // "Omi"
    var sourceType: AudioSourceType { … }   // .omi
}

protocol WearableAudioSource: ConnectableAudioSource {
    func batteryLevels() async -> AsyncStream<Int>
    var latestBatteryLevel: Int? { get async }
    var setupFailureMessage: String? { get async }
}

/// Discovery-only slice of a device transport. PairDeviceSheet and
/// AppModel.makeScanTransport(for:) depend on this, never on OmiTransport —
/// generic code must not name device-module types.
protocol DeviceScanning: Sendable {
    func scan() async -> AsyncStream<WearableDiscovery>
    func stopScan() async
}
```

`OmiTransport` refines `DeviceScanning` (its scan already has this shape; the yielded
discoveries gain `kind: .omi`).

`DeviceKind` is distinct from `AudioSourceType`: the latter includes `.phoneMic`,
which is not pairable. `DeviceKind.rawValue` is persisted inside `PairedDevice` JSON;
`AudioSourceType` remains the pipeline/persistence label.

### Renames (shared types — generic code touches these)

| Current | New | Notes |
|---|---|---|
| `OmiConnectionState` | `DeviceConnectionState` | cases unchanged |
| `OmiBluetoothUnavailableReason` | `BluetoothUnavailableReason` | cases unchanged |
| `OmiDiscovery` | `WearableDiscovery` | gains `kind: DeviceKind`, stamped by the transport's scan |
| `AudioSourceChangeReason.omiDisconnected` | `.wearableDisconnected` | runtime-only enum, safe |
| `AudioSourceChangeReason.omiRecovered` | `.wearableRecovered` | runtime-only enum, safe |
| `OmiDeviceStore` | `PairedDeviceStore` | UserDefaults key unchanged |
| `PairedOmiDevice` | `PairedDevice` | gains `kind` (see Data model) |
| `OmiPairSheet` | `PairDeviceSheet` | copy renders from `DeviceKind` |

### Stays Omi-named (device-internal)

`OmiTransport`, `OmiTransportEvent`, `CoreBluetoothOmiTransport`, `OmiAudioSource`,
`OmiFrameAssembler`, `OmiAudioDecoder`, `OmiConstants`, `Vendored/OmiCodecs.swift`.
These are the Omi device module; future devices bring their own equivalents.

### FailoverAudioSource

- Init becomes `init(wearable: any ConnectableAudioSource, phoneMic: any AudioSource,
  config:)`.
- Internals renamed: `omi` → `wearable`, `omiPumpTask` → `wearablePumpTask`,
  `lastOmiState` → `lastWearableState`.
- Informational `sourceType` changes from hardcoded `.omi` to `wearable.sourceType`
  (identical value today; correct by construction tomorrow).
- All timing/generation/reentrancy logic byte-for-byte equivalent.

### AppModel

- `composePipeline`'s hardcoded construction becomes a per-kind factory:
  `switch paired.kind { case .omi: OmiAudioSource(transport: omiTransportOverride ??
  CoreBluetoothOmiTransport(), deviceID: paired.id) }`. The bound variable is
  `any WearableAudioSource` — the concrete `OmiAudioSource` type no longer escapes
  the factory; battery/setup-failure observation goes through the protocol.
- Observable property renames: `pairedOmiName` → `pairedDeviceName`,
  `omiConnectionState` → `deviceConnectionState`, `omiBatteryLevel` →
  `deviceBatteryLevel`, `omiSetupFailure` → `deviceSetupFailure`, `composedWithOmi` →
  `composedWithWearable`, `omiObservationTasks` → `deviceObservationTasks`.
- Method renames: `pairOmi(_:)` → `pairDevice(_:)`, `forgetOmi()` → `forgetDevice()`,
  `makeOmiScanTransport()` → `makeScanTransport(for kind: DeviceKind) -> any
  DeviceScanning` (switches on kind; one case).
- `bluetoothBannerReason(pairedOmiName:connectionState:)` → renamed parameters to
  match (`pairedDeviceName:`).
- **Exception**: test seams `omiStoreOverride` → `deviceStoreOverride` (it becomes a
  `PairedDeviceStore`), but `omiTransportOverride` keeps its name — it is typed
  `any OmiTransport` and genuinely Omi-specific.

## UI & copy

All user-visible strings render from `DeviceKind.displayName` (or the paired
device's kind), so today's UI is textually identical:

- Settings: section "Omi Device", button "Pair Omi Device…", status/battery rows,
  forget button — `omiSection`/`omiStatusLabel` renamed to `deviceSection`/
  `deviceStatusLabel`.
- `PairDeviceSheet`: title "Pair Omi", empty-state "Looking for Omi devices
  nearby…" — all via `kind.displayName`. Sheet scans one kind (`.omi`) today; a
  future multi-kind sheet unions per-kind scans.
- `ContentView` Bluetooth banner: "…your Omi can't connect…" via displayName.
- `ListeningPipeline` log lines ("Omi disconnected — continuing on iPhone mic",
  "Omi reconnected"): both lines name the wearable, and the failover source's
  informational `sourceType` IS the preferred wearable's type after this change — so
  both render `source.sourceType.displayName` (where `source` is the pipeline's
  switching source). No per-event tracking needed.
- Live Activity: unchanged (already renders `activeSourceType?.displayName`).

## Data model

`PairedDevice` (was `PairedOmiDevice`), same UserDefaults key `"pairedOmiDevice"`:

```swift
struct PairedDevice: Codable, Equatable, Sendable {
    let id: UUID
    let name: String
    let kind: DeviceKind   // decodes via decodeIfPresent ?? .omi
}
```

The custom decode default is the **only migration point** in this change: a legacy
record (no `kind` field) decodes as an Omi pairing. New records encode `kind`
explicitly. Covered by a dedicated test decoding captured legacy JSON.

## File layout (`project.yml` is XcodeGen, directory-sourced — moves are free)

```
Sotto/Wearable/
  WearableTypes.swift        // DeviceKind, DeviceConnectionState,
                             // BluetoothUnavailableReason, WearableDiscovery,
                             // ConnectableAudioSource, WearableAudioSource,
                             // DeviceScanning
  FailoverAudioSource.swift
  PairedDeviceStore.swift
Sotto/Omi/                   // device module, unchanged membership
  OmiTransport.swift         // protocol + OmiTransportEvent (Omi-internal now)
  CoreBluetoothOmiTransport.swift
  OmiAudioSource.swift
  OmiFrameAssembler.swift
  OmiAudioDecoder.swift
  OmiConstants.swift
  Vendored/OmiCodecs.swift
Sotto/App/PairDeviceSheet.swift   // was OmiPairSheet.swift
```

Run `xcodegen generate` after moving files.

## Error handling

Unchanged by design — this refactor introduces no new failure modes. The
`setupFailureMessage` surface (unsupported codec) moves behind
`WearableAudioSource` but keeps its content and flow.

## Testing

- Rename ripple only, no behavioral edits: `OmiDeviceStoreTests` →
  `PairedDeviceStoreTests`, `OmiAudioSourceTests` (kept name — device module),
  `FailoverAudioSourceTests`, `AppModelTests`, `SourceLabelingTests`,
  `ListeningPipelineSourceTests`, `Fakes.swift` doubles.
- One new test: legacy `PairedOmiDevice` JSON (no `kind`) decodes to
  `PairedDevice(kind: .omi)` under the unchanged UserDefaults key.
- Done means: `xcodegen generate` succeeds and the full `xcodebuild test` suite
  passes, with the diff to test files consisting of renames plus the one new
  migration test.

## Risks

- Mechanical rename misses in string-based contexts (log messages, comments) — not
  compiler-checked; sweep with grep for `omi`/`Omi` at the end and justify every
  survivor (device module, persisted raw value, test fixtures, plist copy).
- `SottoWidgets` target compiles two shared files (`SottoActivityAttributes`,
  `ToggleListeningIntent`) — neither touches renamed types, but verify the widget
  target still builds.

## Out of scope

- Any new device support (Limitless Pendant or otherwise).
- Multi-kind scanning UI, batch/offline audio ingestion, transport-layer
  generalization.
- Renaming `omiTransportOverride` or the Omi device module types.

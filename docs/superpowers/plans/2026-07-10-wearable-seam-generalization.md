# Wearable Seam Generalization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Generalize the Omi-specific audio-source seam into a device-agnostic wearable architecture — pure refactor, zero behavior change, zero data migration.

**Architecture:** Introduce `Sotto/Wearable/` holding the generic seam (DeviceKind, DeviceConnectionState, WearableDiscovery, ConnectableAudioSource + WearableAudioSource + DeviceScanning protocols, FailoverAudioSource, PairedDeviceStore). The Omi device module (`Sotto/Omi/`) keeps its transport/assembler/decoder and becomes one implementation behind the seam. AppModel gains a per-kind factory; all user-facing copy renders from `DeviceKind.displayName`.

**Tech Stack:** Swift 6 (strict concurrency, `SWIFT_DEFAULT_ACTOR_ISOLATION: nonisolated`), Swift Testing (`@Test`/`#expect`), XcodeGen (directory-sourced — file moves need `xcodegen generate`), iOS 26 simulator.

**Spec:** `docs/superpowers/specs/2026-07-10-wearable-seam-generalization-design.md` (including its "Planning amendments" section).

## Global Constraints

- **Zero behavior change.** Existing behavioral tests pass with renames only; failover timing/generation/reentrancy logic byte-for-byte equivalent.
- **Frozen persistence:** `AudioSourceType` raw values `"omi"`/`"phoneMic"`; UserDefaults key `"pairedOmiDevice"`; notification identifiers (`"sotto.omiLowBattery"` etc.).
- **Kind-driven copy:** UI still reads "Omi" everywhere today, rendered from `DeviceKind.displayName` — never hardcoded in generic code.
- **Stays Omi-named (device module):** `OmiTransport`, `OmiTransportEvent`, `CoreBluetoothOmiTransport`, `OmiAudioSource`, `OmiFrameAssembler`, `OmiAudioDecoder`, `OmiConstants`, `Vendored/OmiCodecs.swift`, `FakeOmiTransport`, `omiTransportOverride`, `OmiAudioSourceTests`, `OmiFrameAssemblerTests`, `OmiAudioDecoderTests`, `OmiVendoredCodecTests`.
- **Comments:** update doc comments alongside code so no comment references a renamed symbol by its old name. Historic milestone references ("M12 Task 11" etc.) stay.
- Build command: `xcodebuild build -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone 17' -quiet` (expect exit 0).
- Test command: `xcodebuild test -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone 17' -quiet` (expect exit 0, "** TEST SUCCEEDED **").
- After any file create/move/delete: run `xcodegen generate` before building.
- Commit messages: plain, no attribution trailers.

---

### Task 1: Wearable types module + mechanical type renames

One commit — renaming shared types forces every reference at once; the compiler is the checklist. No string/copy changes in this task (copy changes are Task 4; old strings stay literal here even where the surrounding case renames).

**Files:**
- Create: `Sotto/Wearable/WearableTypes.swift`
- Move: `Sotto/Omi/FailoverAudioSource.swift` → `Sotto/Wearable/FailoverAudioSource.swift` (with edits)
- Modify: `Sotto/Omi/OmiTransport.swift`, `Sotto/Omi/CoreBluetoothOmiTransport.swift`, `Sotto/Omi/OmiAudioSource.swift`, `Sotto/Omi/OmiConstants.swift`, `Sotto/App/AppModel.swift`, `Sotto/App/SettingsView.swift`, `Sotto/App/ContentView.swift`, `Sotto/App/OmiPairSheet.swift`, `Sotto/Pipeline/ListeningPipeline.swift`
- Test (modify): `SottoTests/Fakes.swift`, `SottoTests/FailoverAudioSourceTests.swift`, `SottoTests/ListeningPipelineSourceTests.swift`, `SottoTests/AppModelTests.swift`, `SottoTests/OmiAudioSourceTests.swift`

**Interfaces:**
- Produces (later tasks rely on): `DeviceKind` (`.omi`, `.sourceType`, `.displayName`), `DeviceConnectionState`, `BluetoothUnavailableReason`, `WearableDiscovery{id,name,rssi,kind}`, `DeviceScanning{scan()→AsyncStream<WearableDiscovery>, stopScan()}`, `ConnectableAudioSource`, `WearableAudioSource{batteryLevels(), latestBatteryLevel, setupFailureMessage}`, `WearableConstants.lowBatteryThresholdPercent`, `FailoverAudioSource(wearable:phoneMic:config:)`, `AudioSourceChangeReason.wearableDisconnected/.wearableRecovered`.

- [ ] **Step 1: Create `Sotto/Wearable/WearableTypes.swift`**

```swift
import Foundation

/// Catalog of pairable wearable families. All user-facing device copy renders from
/// this — generic code never hardcodes a device family name.
enum DeviceKind: String, Codable, Sendable, CaseIterable {
    case omi

    /// The pipeline/persistence label this family's chunks are tagged with.
    var sourceType: AudioSourceType {
        switch self {
        case .omi: .omi
        }
    }

    /// User-facing family name — delegates to the source-type label so the home
    /// header, Live Activity, Settings, and notifications all agree.
    var displayName: String { sourceType.displayName }
}

/// Reasons Core Bluetooth reports the radio itself as unusable — distinct from a
/// per-device connection failure (see `DeviceConnectionState.unavailable`).
enum BluetoothUnavailableReason: String, Sendable, Equatable {
    case poweredOff
    case unauthorized
    case unsupported
}

/// The connection lifecycle relayed to observers (AppModel, FailoverAudioSource,
/// Settings).
enum DeviceConnectionState: Sendable, Equatable {
    case disconnected
    case connecting
    case connected
    case streaming
    case unavailable(BluetoothUnavailableReason)
}

/// A discovered-but-not-yet-paired wearable peripheral. `kind` is stamped by the
/// transport doing the scanning (each transport scans exactly one family).
struct WearableDiscovery: Sendable, Equatable, Identifiable {
    let id: UUID
    let name: String
    let rssi: Int
    let kind: DeviceKind
}

/// Discovery-only slice of a device transport. `PairDeviceSheet` and
/// `AppModel.makeScanTransport(for:)` depend on this, never on a device module's
/// transport protocol — generic code must not name device-module types.
protocol DeviceScanning: Sendable {
    func scan() async -> AsyncStream<WearableDiscovery>
    func stopScan() async
}

/// An `AudioSource` that also exposes its connection lifecycle as a multicast stream.
protocol ConnectableAudioSource: AudioSource {
    /// New independent stream per call (multicast) — FailoverAudioSource and AppModel
    /// both observe.
    func connectionStates() async -> AsyncStream<DeviceConnectionState>
}

/// The full wearable seam: what AppModel's Settings observation needs beyond
/// failover's needs. One implementation per device family — the device module owns
/// its transport, framing, and decode; this is the portable boundary (decoded 16 kHz
/// chunks + lifecycle + battery).
protocol WearableAudioSource: ConnectableAudioSource {
    func batteryLevels() async -> AsyncStream<Int>
    var latestBatteryLevel: Int? { get async }
    var setupFailureMessage: String? { get async }
}

enum WearableConstants {
    static let lowBatteryThresholdPercent = 15
}
```

- [ ] **Step 2: Rewrite `Sotto/Omi/OmiTransport.swift` to only the device-internal protocol**

The moved types (`OmiBluetoothUnavailableReason`, `OmiDiscovery`, `OmiConnectionState`, `ConnectableAudioSource`) are deleted here; `OmiTransport` refines `DeviceScanning`. Full new file content:

```swift
import Foundation

/// Lifecycle events surfaced by the transport while `events(deviceID:)` is active.
enum OmiTransportEvent: Sendable, Equatable {
    case connecting
    case connected(codecValue: UInt8)
    case audioNotification(Data)
    case batteryLevel(Int)                 // percent 0–100
    case disconnected
    case bluetoothUnavailable(BluetoothUnavailableReason)
}

/// The hardware quarantine seam: everything Core Bluetooth-shaped lives behind this
/// protocol so `OmiAudioSource` (and its tests) never touch CoreBluetooth directly.
/// Device-internal on purpose — the generic seam is `WearableAudioSource` (and
/// `DeviceScanning` for pairing); handshakes don't share a shape across vendors, so
/// each device family brings its own transport protocol.
protocol OmiTransport: DeviceScanning {
    /// Connect to the peripheral and MAINTAIN the connection (immediate pending
    /// re-connect on disconnect) until stopEvents(). Repeatable after stopEvents().
    func events(deviceID: UUID) async -> AsyncStream<OmiTransportEvent>
    /// MUST finish the stream returned by `events(deviceID:)` on every path (including
    /// when called while a connect is pending) — `OmiAudioSource.stop()` awaits its event
    /// pump to completion and would hang forever on a transport that never finishes it.
    func stopEvents() async
}
```

- [ ] **Step 3: Update `Sotto/Omi/CoreBluetoothOmiTransport.swift`**

Two changes:
1. `scan()` signature/stream type: `AsyncStream<OmiDiscovery>` → `AsyncStream<WearableDiscovery>` (both the method and the `scanContinuation` property type).
2. In `didDiscover`, yield the new struct with kind:

```swift
        if publicScanActive {
            scanContinuation?.yield(WearableDiscovery(
                id: peripheral.identifier,
                name: peripheral.name ?? "Omi device",
                rssi: RSSI.intValue,
                kind: .omi))
        }
```

- [ ] **Step 4: Update `Sotto/Omi/OmiAudioSource.swift`**

- Conformance: `actor OmiAudioSource: ConnectableAudioSource` → `actor OmiAudioSource: WearableAudioSource` (members already satisfy the protocol — actor-isolated properties/methods witness the `async` requirements, same pattern as the existing `connectionStates()` conformance).
- Type renames throughout: `OmiConnectionState` → `DeviceConnectionState` (the `stateContinuations` dictionary type, `connectionStates()` return type, `yieldState` parameter).
- Doc comment on line 3: "AudioSource over an OmiTransport" stays (accurate).

- [ ] **Step 5: Move + update `FailoverAudioSource.swift` to `Sotto/Wearable/`**

`git mv Sotto/Omi/FailoverAudioSource.swift Sotto/Wearable/FailoverAudioSource.swift`, then rename within it (no logic changes — every guard, timer, and generation check identical):

| Old | New |
|---|---|
| `case initial, omiDisconnected, omiRecovered, captureUnavailable` | `case initial, wearableDisconnected, wearableRecovered, captureUnavailable` |
| `nonisolated let sourceType: AudioSourceType = .omi` | `nonisolated let sourceType: AudioSourceType` (assigned in init) |
| `private let omi: any ConnectableAudioSource` | `private let wearable: any ConnectableAudioSource` |
| `init(omi: any ConnectableAudioSource, phoneMic:` … | `init(wearable: any ConnectableAudioSource, phoneMic:` … |
| `omiPumpTask` | `wearablePumpTask` |
| `lastOmiState: OmiConnectionState` | `lastWearableState: DeviceConnectionState` |
| `handle(_ state: OmiConnectionState)` | `handle(_ state: DeviceConnectionState)` |
| `await omi.connectionStates()` / `omi.start()` / `omi.stop()` | `wearable.…` |
| `forward(chunk, from: .omi)` (wearable pump) | `forward(chunk, from: sourceType)` |
| `activate(.omi, reason: .initial)` | `activate(sourceType, reason: .initial)` |
| `activate(.omi, reason: .omiRecovered)` | `activate(sourceType, reason: .wearableRecovered)` |
| `reason: .omiDisconnected` (both sites) | `reason: .wearableDisconnected` |
| `(reason == .initial && hasEmittedInitial) ? .omiRecovered : reason` | `… ? .wearableRecovered : reason` |

New init body:

```swift
    init(wearable: any ConnectableAudioSource, phoneMic: any AudioSource,
         config: FailoverConfig = FailoverConfig()) {
        self.wearable = wearable
        self.phoneMic = phoneMic
        self.config = config
        // Informational: the preferred source. Was hardcoded .omi; now whatever
        // wearable family this failover fronts.
        self.sourceType = wearable.sourceType
    }
```

Update the class-level doc comment ("Prefers the Omi whenever it streams" → "Prefers the wearable whenever it streams") and the concurrency-note comments that say "Omi"/"omi.stop()" to say "wearable". The `AudioSourceChangeReason`/`AudioSourceChange`/`SourceSwitchingAudioSource`/`RouteChangeHandling` declarations stay in this file.

- [ ] **Step 6: Update `Sotto/Omi/OmiConstants.swift`** — delete the `lowBatteryThresholdPercent` line (moved to `WearableConstants`).

- [ ] **Step 7: Ripple pure type/case renames through remaining app files**

Only these mechanical substitutions (member/property renames are Task 3; copy is Task 4):
- `Sotto/App/AppModel.swift`: `OmiConnectionState` → `DeviceConnectionState` (property + `bluetoothBannerReason` signature), `OmiBluetoothUnavailableReason` → `BluetoothUnavailableReason`, `OmiDiscovery` → `WearableDiscovery` (`pairOmi` parameter), `FailoverAudioSource(omi: omi, phoneMic:` → `FailoverAudioSource(wearable: omi, phoneMic:`, `OmiConstants.lowBatteryThresholdPercent` → `WearableConstants.lowBatteryThresholdPercent` (both readings in `applyOmiBattery`).
- `Sotto/App/OmiPairSheet.swift`: `@State private var discoveries: [OmiDiscovery]` → `[WearableDiscovery]`.
- `Sotto/Pipeline/ListeningPipeline.swift`: `case .omiDisconnected:` → `case .wearableDisconnected:`, `case .omiRecovered:` → `case .wearableRecovered:` (strings inside untouched this task).
- `Sotto/App/SettingsView.swift` / `Sotto/App/ContentView.swift`: no type names used — untouched this task.

- [ ] **Step 8: Ripple through tests**

- `SottoTests/Fakes.swift`:
  - `FakeOmiTransport`: `scan() -> AsyncStream<OmiDiscovery>` → `AsyncStream<WearableDiscovery>`, `scanContinuation` type, `emitDiscovery(_ d: OmiDiscovery)` → `(_ d: WearableDiscovery)`.
  - `FakeConnectableAudioSource`: every `OmiConnectionState` → `DeviceConnectionState` (dictionary, `connectionStates()`, `setState`).
- `SottoTests/FailoverAudioSourceTests.swift` + `SottoTests/ListeningPipelineSourceTests.swift`: `FailoverAudioSource(omi:` → `FailoverAudioSource(wearable:`, `.omiDisconnected` → `.wearableDisconnected`, `.omiRecovered` → `.wearableRecovered`, `OmiConnectionState` → `DeviceConnectionState`.
- `SottoTests/AppModelTests.swift` + `SottoTests/OmiAudioSourceTests.swift`: `OmiConnectionState` → `DeviceConnectionState`, `OmiDiscovery(id:name:rssi:)` → `WearableDiscovery(id:name:rssi:kind: .omi)`, `.bluetoothUnavailable` payloads' type name if spelled out.

Sweep to catch stragglers (must return nothing):

```bash
grep -rn "OmiConnectionState\|OmiBluetoothUnavailableReason\|OmiDiscovery\|omiDisconnected\|omiRecovered\|lowBatteryThresholdPercent" Sotto SottoTests --include="*.swift" | grep -v "WearableConstants.lowBatteryThresholdPercent" | grep -v "Sotto/Wearable/WearableTypes.swift"
```

- [ ] **Step 9: Regenerate project and run the full suite**

```bash
xcodegen generate
xcodebuild test -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone 17' -quiet
```

Expected: `** TEST SUCCEEDED **`, zero test-count change.

- [ ] **Step 10: Commit**

```bash
git add -A
git commit -m "refactor: extract device-agnostic wearable seam types from the Omi module"
```

---

### Task 2: PairedDeviceStore with kind (TDD)

**Files:**
- Move: `Sotto/Omi/OmiDeviceStore.swift` → `Sotto/Wearable/PairedDeviceStore.swift` (with edits)
- Move: `SottoTests/OmiDeviceStoreTests.swift` → `SottoTests/PairedDeviceStoreTests.swift` (with edits)
- Modify: `Sotto/App/AppModel.swift`, `SottoTests/AppModelTests.swift`

**Interfaces:**
- Consumes: `DeviceKind` (Task 1).
- Produces: `PairedDeviceStore` (`device: PairedDevice?`, `pair(_:)`, `forget()`, `init(defaults:)`), `PairedDevice{id: UUID, name: String, kind: DeviceKind}` with legacy-tolerant decoding. UserDefaults key stays `"pairedOmiDevice"`.

- [ ] **Step 1: Write the failing migration test**

In `SottoTests/OmiDeviceStoreTests.swift` (renamed in Step 4; write the test first against the NEW names so it fails to compile — that is the failing state for a rename+behavior task):

```swift
    @Test func legacyRecordWithoutKindDecodesAsOmiPairing() throws {
        // Pre-generalization records (struct PairedOmiDevice { id, name }) live under
        // the SAME UserDefaults key and must decode as an Omi pairing — this is the
        // refactor's only migration point.
        let suite = UserDefaults(suiteName: "paired-device-store-legacy-\(UUID().uuidString)")!
        let id = UUID(uuidString: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F")!
        let legacy = Data(#"{"id":"E621E1F8-C36C-495A-93FC-0C247A3E6E5F","name":"Omi DevKit 2"}"#.utf8)
        suite.set(legacy, forKey: "pairedOmiDevice")

        let store = PairedDeviceStore(defaults: suite)

        #expect(store.device == PairedDevice(id: id, name: "Omi DevKit 2", kind: .omi))
    }
```

- [ ] **Step 2: Run to verify it fails**

```bash
xcodebuild build-for-testing -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone 17' -quiet
```

Expected: FAIL — `cannot find 'PairedDeviceStore' in scope`.

- [ ] **Step 3: Implement `PairedDeviceStore`**

`git mv Sotto/Omi/OmiDeviceStore.swift Sotto/Wearable/PairedDeviceStore.swift`, full new content:

```swift
import Foundation

/// Persists the single paired wearable (spec: auto-prefer one device; pair/forget
/// only). The UserDefaults key predates the multi-device generalization and is kept
/// verbatim so existing pairings survive.
final class PairedDeviceStore: Sendable {
    private static let key = "pairedOmiDevice"
    // UserDefaults isn't marked Sendable on this SDK, but it is documented as internally
    // thread-safe (all instance methods may be called from any thread) — nonisolated(unsafe)
    // is safe here, matching `SettingsStore.defaults`.
    private nonisolated(unsafe) let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var device: PairedDevice? {
        guard let data = defaults.data(forKey: Self.key) else { return nil }
        return try? JSONDecoder().decode(PairedDevice.self, from: data)
    }

    func pair(_ device: PairedDevice) {
        defaults.set(try? JSONEncoder().encode(device), forKey: Self.key)
    }

    func forget() {
        defaults.removeObject(forKey: Self.key)
    }
}

struct PairedDevice: Codable, Equatable, Sendable {
    let id: UUID
    let name: String
    let kind: DeviceKind

    init(id: UUID, name: String, kind: DeviceKind) {
        self.id = id
        self.name = name
        self.kind = kind
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        // Legacy records (pre-generalization `PairedOmiDevice`) carry no kind field —
        // they are Omi pairings by construction.
        kind = try container.decodeIfPresent(DeviceKind.self, forKey: .kind) ?? .omi
    }
}
```

- [ ] **Step 4: Update call sites to compile**

- `git mv SottoTests/OmiDeviceStoreTests.swift SottoTests/PairedDeviceStoreTests.swift`; in it: `struct OmiDeviceStoreTests` → `struct PairedDeviceStoreTests`, `OmiDeviceStore(` → `PairedDeviceStore(`, `PairedOmiDevice(id: UUID(), name: "…")` → `PairedDevice(id: UUID(), name: "…", kind: .omi)`, suite-name prefixes `"omi-device-store-…"` → `"paired-device-store-…"`.
- `Sotto/App/AppModel.swift`: `OmiDeviceStore` → `PairedDeviceStore` (override property type + both `?? OmiDeviceStore()` constructions), `PairedOmiDevice(id: discovery.id, name: discovery.name)` → `PairedDevice(id: discovery.id, name: discovery.name, kind: discovery.kind)`.
- `SottoTests/AppModelTests.swift`: same two type renames wherever the store/struct are constructed.

- [ ] **Step 5: Regenerate, run full suite**

```bash
xcodegen generate
xcodebuild test -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone 17' -quiet
```

Expected: `** TEST SUCCEEDED **` including the new `legacyRecordWithoutKindDecodesAsOmiPairing`.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "refactor: PairedDeviceStore with device kind, legacy records decode as Omi"
```

---

### Task 3: AppModel — per-kind factory, WearableAudioSource seam, property/method renames

**Files:**
- Modify: `Sotto/App/AppModel.swift`, `Sotto/App/SettingsView.swift`, `Sotto/App/ContentView.swift`, `Sotto/App/OmiPairSheet.swift`, `Sotto/Pipeline/ListeningPipeline.swift` (one comment)
- Test (modify): `SottoTests/AppModelTests.swift`, `SottoTests/ListeningPipelineSourceTests.swift` (comment/helper references)

**Interfaces:**
- Consumes: `PairedDeviceStore`/`PairedDevice` (Task 2), `WearableAudioSource`, `DeviceScanning`, `WearableConstants` (Task 1).
- Produces (Task 4 relies on): `model.pairedDeviceName`, `model.pairedDeviceKind: DeviceKind?`, `model.deviceConnectionState`, `model.deviceBatteryLevel`, `model.deviceSetupFailure`, `model.pairDevice(_: WearableDiscovery)`, `model.forgetDevice()`, `model.makeScanTransport(for: DeviceKind) -> any DeviceScanning`, `AppModel.bluetoothBannerReason(pairedDeviceName:connectionState:)`.

- [ ] **Step 1: Rename AppModel's stored surface**

| Old | New |
|---|---|
| `omiStoreOverride: OmiDeviceStore?` (property + init param) | `deviceStoreOverride: PairedDeviceStore?` |
| `pairedOmiName` | `pairedDeviceName` |
| — (new) | `private(set) var pairedDeviceKind: DeviceKind?` |
| `composedWithOmi` | `composedWithWearable` |
| `omiBatteryLevel` | `deviceBatteryLevel` |
| `omiConnectionState` | `deviceConnectionState` |
| `omiSetupFailure` | `deviceSetupFailure` |
| `omiObservationTasks` | `deviceObservationTasks` |
| `pairOmi(_:)` | `pairDevice(_:)` |
| `forgetOmi()` | `forgetDevice()` |
| `applyOmiBattery(_:)` | `applyDeviceBattery(_:)` |
| `makeOmiScanTransport()` | `makeScanTransport(for:)` |
| `bluetoothBannerReason(pairedOmiName:…)` | `bluetoothBannerReason(pairedDeviceName:…)` |

`omiTransportOverride` keeps its name (typed `any OmiTransport`, genuinely Omi-specific; its doc comment updated to say it feeds the factory's `.omi` branch). Update doc comments that reference renamed members.

- [ ] **Step 2: Rewrite `composePipeline`'s source construction as the per-kind factory**

Replace the current `if let paired = omiStore.device { … }` block (AppModel.swift:884–901) with:

```swift
        // Auto-prefer a paired wearable (spec "Selection model") — failover to the
        // phone mic is the selection logic itself; no paired device ⇒ exactly the old
        // construction path (byte-identical behavior for phone-mic-only users).
        let deviceStore = deviceStoreOverride ?? PairedDeviceStore()
        var wearableSource: (any WearableAudioSource)?
        var plainPhoneMic: PhoneMicAudioSource?
        let source: any AudioSource
        if let paired = deviceStore.device {
            // THE extension point: one WearableAudioSource implementation per device
            // family. A new device kind adds a case here and its own module — nothing
            // downstream of this switch changes.
            let wearable: any WearableAudioSource
            switch paired.kind {
            case .omi:
                wearable = OmiAudioSource(
                    transport: omiTransportOverride ?? CoreBluetoothOmiTransport(),
                    deviceID: paired.id)
            }
            wearableSource = wearable
            source = FailoverAudioSource(wearable: wearable, phoneMic: PhoneMicAudioSource())
            pairedDeviceName = paired.name
            pairedDeviceKind = paired.kind
            composedWithWearable = true
        } else {
            let phoneMic = PhoneMicAudioSource()
            plainPhoneMic = phoneMic
            source = phoneMic
            pairedDeviceName = nil
            pairedDeviceKind = nil
            composedWithWearable = false
        }
```

The observation block's `if let omiSource { … }` becomes `if let wearableSource { … }` with `omiSource.` → `wearableSource.` inside (calls stay identical — they now go through the protocol); `self?.omiConnectionState/omiSetupFailure` → renamed properties; `applyOmiBattery` → `applyDeviceBattery`. The teardown at the top of `composePipeline` resets the renamed properties (`deviceConnectionState`, `deviceBatteryLevel`, `deviceSetupFailure`, `deviceObservationTasks`) and additionally must NOT reset `pairedDeviceKind` there (it is assigned in both branches below, exactly like `pairedDeviceName`).

- [ ] **Step 3: Update pair/forget/scan/rebuild members**

```swift
    /// Settings "Pair Omi Device…": the pair sheet owns its own scan transport
    /// lifecycle, this just hands out a fresh one for the requested device family.
    func makeScanTransport(for kind: DeviceKind) -> any DeviceScanning {
        switch kind {
        case .omi: CoreBluetoothOmiTransport()
        }
    }

    func pairDevice(_ discovery: WearableDiscovery) async {
        (deviceStoreOverride ?? PairedDeviceStore()).pair(
            PairedDevice(id: discovery.id, name: discovery.name, kind: discovery.kind))
        pairedDeviceName = discovery.name
        pairedDeviceKind = discovery.kind
        await rebuildPipelineIfIdle()
    }

    func forgetDevice() async {
        (deviceStoreOverride ?? PairedDeviceStore()).forget()
        pairedDeviceName = nil
        pairedDeviceKind = nil
        deviceBatteryLevel = nil
        deviceConnectionState = nil
        await rebuildPipelineIfIdle()
    }
```

(Keep each function's existing doc comment, reworded for the new names.) In `rebuildIfSourceShapeChanged()`: `(omiStoreOverride ?? OmiDeviceStore()).device != nil` → `(deviceStoreOverride ?? PairedDeviceStore()).device != nil`, `composedWithOmi` → `composedWithWearable`. In `applyDeviceBattery` keep the body but the notification call is Task 4 — this task only renames the function and its `WearableConstants` reads (already done in Task 1).

- [ ] **Step 4: Update views/tests for the renamed members (references only, copy unchanged)**

- `SettingsView.swift`: `model.pairedOmiName` → `model.pairedDeviceName`, `model.omiBatteryLevel` → `model.deviceBatteryLevel`, `model.omiSetupFailure` → `model.deviceSetupFailure`, `model.omiConnectionState` → `model.deviceConnectionState`, `model.forgetOmi()` → `model.forgetDevice()`.
- `ContentView.swift`: `bluetoothBannerReason(pairedOmiName: model.pairedOmiName, …)` → `bluetoothBannerReason(pairedDeviceName: model.pairedDeviceName, connectionState: model.deviceConnectionState)`; the other `model.pairedOmiName` read (home header gate) → `model.pairedDeviceName`.
- `OmiPairSheet.swift`: `model.makeOmiScanTransport()` → `model.makeScanTransport(for: .omi)`, `model.pairOmi(discovery)` → `model.pairDevice(discovery)`.
- `ListeningPipeline.swift`: comment "no direct handle on `AppModel.pairedOmiName`" → `AppModel.pairedDeviceName`.
- `AppModelTests.swift`: `omiStoreOverride:` label → `deviceStoreOverride:`, and every renamed member/method reference.
- `ListeningPipelineSourceTests.swift`: any renamed references.

- [ ] **Step 5: Run full suite**

```bash
xcodebuild test -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone 17' -quiet
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "refactor: AppModel composes wearables through a per-kind factory and the WearableAudioSource seam"
```

---

### Task 4: Kind-driven copy — PairDeviceSheet, Settings, banner, pipeline logs, notifications

Behavior-identical output today (every rendered string still reads "Omi"), but no generic file hardcodes the family name anymore.

**Files:**
- Move: `Sotto/App/OmiPairSheet.swift` → `Sotto/App/PairDeviceSheet.swift` (with edits)
- Modify: `Sotto/App/SettingsView.swift`, `Sotto/App/ContentView.swift`, `Sotto/Pipeline/ListeningPipeline.swift`, `Sotto/Notifications/NotificationScheduling.swift`
- Test (modify): `SottoTests/Fakes.swift`, `SottoTests/ListeningPipelineSourceTests.swift` (if notification-seam assertions reference the renamed method), `SottoTests/AppModelTests.swift` (battery-notification assertions, if any)

**Interfaces:**
- Consumes: `DeviceKind.displayName`, `model.pairedDeviceKind`, `makeScanTransport(for:)` (Tasks 1/3).
- Produces: `NotificationScheduling.scheduleSourceFallbackNotification(deviceName: String)`, `scheduleCaptureUnavailableNotification(deviceName: String)`, `scheduleLowBatteryNotification(deviceName: String, level: Int)`.

- [ ] **Step 1: Rename + generalize the pair sheet**

`git mv Sotto/App/OmiPairSheet.swift Sotto/App/PairDeviceSheet.swift`. `struct OmiPairSheet` → `struct PairDeviceSheet` with a kind the caller passes (SettingsView passes `.omi`):

```swift
struct PairDeviceSheet: View {
    let model: AppModel
    /// The device family this sheet scans for. One kind per presentation — a future
    /// multi-device picker unions per-kind scans instead of widening this sheet.
    let kind: DeviceKind
    @Environment(\.dismiss) private var dismiss
    @State private var discoveries: [WearableDiscovery] = []
```

Copy renders from `kind`: `Text("Looking for \(kind.displayName) devices nearby…")`, `.navigationTitle("Pair \(kind.displayName)")`. Scan setup becomes `let transport = model.makeScanTransport(for: kind)`. Body/dedup/cancellation logic unchanged. Update the file-header doc comment ("Settings "Pair Omi Device…"" → kind-driven wording). In `SettingsView.swift`: `.sheet(isPresented: $showPairSheet) { PairDeviceSheet(model: model, kind: .omi) }`.

- [ ] **Step 2: Settings section copy from the kind**

In `SettingsView.swift`, rename `omiSection` → `deviceSection` (and its use in `body`), `omiStatusLabel` → `deviceStatusLabel` (reads `model.deviceConnectionState`, cases unchanged), and render copy from a kind:

```swift
    /// The one pairable device family today. A future multi-device Settings screen
    /// replaces this constant with a picker, not this section's structure.
    private let pairableKind: DeviceKind = .omi

    private var deviceSection: some View {
        Section("\(pairableKind.displayName) Device") {
            if let name = model.pairedDeviceName {
```

Paired-branch copy is name-driven already (unchanged); unpaired branch:

```swift
                Button("Pair \(pairableKind.displayName) Device…") { showPairSheet = true }
                Text("Wear an \(pairableKind.displayName) pendant and Sotto records from it automatically, falling back to the iPhone mic when it's out of range.")
                    .font(.caption).foregroundStyle(.secondary)
```

- [ ] **Step 3: Bluetooth banner copy from the paired kind**

In `ContentView.swift`, the banner block renders the paired family name:

```swift
        if let reason = AppModel.bluetoothBannerReason(
            pairedDeviceName: model.pairedDeviceName, connectionState: model.deviceConnectionState) {
            let deviceName = model.pairedDeviceKind?.displayName ?? "device"
            VStack(spacing: 6) {
                NoticeBanner(
                    text: reason == .poweredOff
                        ? "Bluetooth is off — your \(deviceName) can't connect. Recording uses the iPhone mic."
                        : "Sotto needs Bluetooth permission to use your \(deviceName). Recording uses the iPhone mic.",
                    color: .red)
```

(`pairedDeviceKind` is non-nil whenever the banner shows — the banner requires `pairedDeviceName != nil` and both are set together; the `?? "device"` fallback is compiler-required only.)

- [ ] **Step 4: Notification copy parameterized**

`NotificationScheduling.swift` protocol:

```swift
    /// M12: the wearable dropped and the pipeline rolled over to the iPhone mic
    /// automatically — recording continues, but capture quality may have changed.
    func scheduleSourceFallbackNotification(deviceName: String) async
    /// M12: the wearable dropped AND the iPhone mic could not start — nothing is capturing.
    func scheduleCaptureUnavailableNotification(deviceName: String) async
    /// M12: the wearable's reported battery level is low.
    func scheduleLowBatteryNotification(deviceName: String, level: Int) async
```

`UserNotificationScheduler` bodies interpolate (identifiers unchanged, including `omiLowBatteryIdentifier`'s stored string `"sotto.omiLowBattery"` — it's a dedup key, not copy):

```swift
    func scheduleSourceFallbackNotification(deviceName: String) async {
        let content = UNMutableNotificationContent()
        content.title = "\(deviceName) disconnected"
        content.body = "Recording continues on the iPhone microphone — audio may be muffled if the phone is in a pocket."
        …
    func scheduleCaptureUnavailableNotification(deviceName: String) async {
        …
        content.body = "The \(deviceName) disconnected and the iPhone microphone could not start. Open Sotto to resume."
        …
    func scheduleLowBatteryNotification(deviceName: String, level: Int) async {
        …
        content.title = "\(deviceName) battery low"
```

Rename the private identifier constant `omiLowBatteryIdentifier` → `lowBatteryIdentifier` (its VALUE stays `"sotto.omiLowBattery"` with a comment: `// value predates the generalization; changing it would orphan pending notifications`).

- [ ] **Step 5: Call sites pass the family name**

`ListeningPipeline.handleSourceChange` — copy renders from the switching source's own type (`self.source.sourceType` is the preferred wearable's type after Task 1; `source`/`previousSource` locals shadow, hence `self.`):

```swift
        case .wearableDisconnected:
            guard let source = change.source else { return }
            let snapshot = await recorder.rollover(to: source)
            activeSourceType = source
            hasNotifiedCaptureUnavailable = false
            apply(snapshot)
            if previousSource != source {
                log("\(self.source.sourceType.displayName) disconnected — continuing on \(source.displayName)")
                await notifications?.scheduleSourceFallbackNotification(
                    deviceName: self.source.sourceType.displayName)
            }
        case .wearableRecovered:
            …
            if previousSource != source {
                log("\(self.source.sourceType.displayName) reconnected")
            }
        case .captureUnavailable:
            activeSourceType = nil
            if !hasNotifiedCaptureUnavailable {
                hasNotifiedCaptureUnavailable = true
                log("Nothing capturing — \(source.sourceType.displayName) gone and mic unavailable")
                await notifications?.scheduleCaptureUnavailableNotification(
                    deviceName: source.sourceType.displayName)
            }
```

(in `.captureUnavailable` there is no shadowing local, so bare `source` is the stored property.) Update the doc comments in this method and `liveActivitySourceLabel` that say "Omi" to say "wearable".

`AppModel.applyDeviceBattery`:

```swift
    private func applyDeviceBattery(_ level: Int) {
        deviceBatteryLevel = level
        if level <= WearableConstants.lowBatteryThresholdPercent, !lowBatteryNotified {
            lowBatteryNotified = true
            if let kind = pairedDeviceKind {
                Task {
                    await UserNotificationScheduler()
                        .scheduleLowBatteryNotification(deviceName: kind.displayName, level: level)
                }
            }
        }
        if level > WearableConstants.lowBatteryThresholdPercent + 10 { lowBatteryNotified = false }
    }
```

- [ ] **Step 6: Update the fakes and any assertions**

`SottoTests/Fakes.swift`:

```swift
    func scheduleSourceFallbackNotification(deviceName: String) { sourceFallbackCount += 1 }
    func scheduleCaptureUnavailableNotification(deviceName: String) { captureUnavailableCount += 1 }
    func scheduleLowBatteryNotification(deviceName: String, level: Int) { lowBatteryLevels.append(level) }
```

Same three signature updates in `GatedNotificationScheduler` (empty bodies). Fix any test call/assertion sites the compiler flags (e.g. direct invocations of the old method names).

- [ ] **Step 7: Regenerate (file moved), run full suite**

```bash
xcodegen generate
xcodebuild test -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone 17' -quiet
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "refactor: render all wearable copy from DeviceKind; PairDeviceSheet replaces OmiPairSheet"
```

---

### Task 5: Final sweep + verification

**Files:** none expected (fixes only if the sweep finds strays).

- [ ] **Step 1: Grep sweep — justify every survivor**

```bash
grep -rni "omi" Sotto SottoTests SottoWidgets --include="*.swift" -l | grep -v "^Sotto/Omi/"
```

Every hit outside `Sotto/Omi/` must be one of (fix anything else):
1. `AudioSourceType.omi` / raw value `"omi"` / its `displayName` (`AudioTypes.swift`, persistence code, tests) — frozen persistence label.
2. `omiTransportOverride` and `OmiTransport`/`OmiAudioSource`/`CoreBluetoothOmiTransport` type references inside AppModel's factory `.omi` branch and its test seams — the factory is where device-module names are allowed.
3. The UserDefaults key `"pairedOmiDevice"` and notification identifier `"sotto.omiLowBattery"` (+ their "predates the generalization" comments).
4. Omi-module test files (`OmiAudioSourceTests`, `OmiFrameAssemblerTests`, `OmiAudioDecoderTests`, `OmiVendoredCodecTests`, `FakeOmiTransport`) and test fixture strings ("Omi DevKit 2").
5. `DeviceKind.omi` case references and kind-driven copy call sites (`pairableKind`, `PairDeviceSheet(model:kind: .omi)`).
6. Historical doc comments quoting spec/milestone names, and `project.yml`'s `NSBluetoothAlwaysUsageDescription` (out of scope per spec).

- [ ] **Step 2: Confirm zero diff to persisted formats**

```bash
grep -rn "case omi\b\|\"omi\"\|pairedOmiDevice\|sotto.omiLowBattery" Sotto --include="*.swift"
```

Expected: `AudioSourceType.omi` case intact, store key intact, identifier intact.

- [ ] **Step 3: Full clean verification (app + widget targets + tests)**

```bash
xcodegen generate
xcodebuild build -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone 17' -quiet
xcodebuild test -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone 17' -quiet
```

Expected: both exit 0; `** TEST SUCCEEDED **`. (The Sotto scheme builds and embeds SottoWidgets — the widget-target risk from the spec is covered by the build step.)

- [ ] **Step 4: Commit (only if the sweep changed anything)**

```bash
git add -A
git commit -m "refactor: wearable seam sweep — remove stray Omi references from generic code"
```

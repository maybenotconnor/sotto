# Omi Failover Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement `docs/superpowers/specs/2026-07-23-omi-failover-redesign-design.md` — mic-first capture (3 s startup race deleted), a recoverable waiting state with honest UI, a loud truthful "Recording stopped" notification, and transport/Settings status honesty.

**Architecture:** Two independent phases. Phase B (Tasks 1–2): transport error surfacing + Settings status honesty — small, low-risk, no behavior coupling to Phase A. Phase A (Tasks 3–7): invert the failover (phone mic starts instantly at Start; the wearable upgrades on first `.streaming`), turn `.captureUnavailable` into a waiting state (derived UI, foreground mic retry, 30 s loud notification with cancel-on-heal), and amend SPEC.md.

**Tech Stack:** Swift 6 (strict concurrency, actors), SwiftUI, CoreBluetooth, ActivityKit, UserNotifications, Swift Testing (`@Test` / `#expect` — NOT XCTest).

## Global Constraints

- Commit messages: plain, conventional (`fix:`/`feat:`/`docs:`), **no attribution trailers of any kind** (no Co-Authored-By, no session links).
- The working tree already contains uncommitted os_log diagnostics in `Sotto/Wearable/FailoverAudioSource.swift` and `Sotto/Pipeline/ListeningPipeline.swift` (subsystem `app.decanlys.sotto`, category `Failover`). These are KEPT per spec §5 — Task 3's and Task 6's commits absorb them. Never revert them.
- Tests use Swift Testing: `import Testing`, `@Test func name()`, `#expect(...)`. Match the idioms in `SottoTests/FailoverAudioSourceTests.swift`.
- Build check: `xcodebuild -project Sotto.xcodeproj -scheme Sotto -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -3` → expect `** BUILD SUCCEEDED **`.
- Test run: first discover an available simulator once with `xcrun simctl list devices available | grep iPhone | head -3` and use its name in `DEST="platform=iOS Simulator,name=<name>"`. Then: `xcodebuild -project Sotto.xcodeproj -scheme Sotto -destination "$DEST" test -only-testing:SottoTests/<SuiteName> 2>&1 | tail -8` → expect `** TEST SUCCEEDED **`.
- User-facing copy is fixed by the spec (provisional strings are final unless the user says otherwise): idle device status `"Connects when listening"`; device-section caption `"Live status appears while Sotto is listening."`; waiting header label `"Waiting"`; waiting subtitle `"Can't record right now — waiting for <device> or the iPhone mic."`; notification delay exactly 30 s via one named constant.
- Generic code never hardcodes a device family name — device names come from `AudioSourceType.displayName` / `DeviceKind.displayName` (see `Sotto/Wearable/WearableTypes.swift`).

---

## Phase B — status honesty (independent, lands first)

### Task 1: Transport negotiation-error surfacing

**Files:**
- Modify: `Sotto/Omi/CoreBluetoothOmiTransport.swift`

**Interfaces:**
- Consumes: existing `OmiTransportEvent` enum (`.connecting`, `.disconnected`, …) — no signature changes.
- Produces: no API changes. Behavior only: `didFailToConnect` now yields `.connecting` after `.disconnected`; negotiation failures on a connected peripheral cancel the link so the existing `didDisconnectPeripheral` path drives `.disconnected` → `.connecting` → pending reconnect.

There is no unit seam here (`CBPeripheral`/`CBCentralManager` cannot be constructed in tests) — the spec assigns these paths to manual verification. The cycle is: implement → build → commit.

- [ ] **Step 1: Add the logger and the retry helper**

In `Sotto/Omi/CoreBluetoothOmiTransport.swift`, add `import os` under `import Foundation`, then add inside the class (below the `didConnectThisSession` property):

```swift
    /// Redesign spec §4: negotiation failures must be visible and self-healing, never a
    /// silent pin at "Connecting…". Error-level so a retry loop is visible in diagnostics.
    private let logger = Logger(subsystem: "app.decanlys.sotto", category: "OmiTransport")

    /// Negotiation failed on a CONNECTED peripheral (service/characteristic discovery or
    /// the codec read). Cancel the link and let didDisconnectPeripheral's existing path
    /// drive the retry — it yields .disconnected → .connecting and re-issues connect, so
    /// the UI reads "Connecting…" during the retry instead of pinning over a dead link.
    /// No explicit backoff: retry cadence is gated by the BLE stack's own connect latency,
    /// matching the existing pending-retry pattern (spec §4).
    private func retryNegotiation(_ peripheral: CBPeripheral, because reason: String) {
        logger.error("negotiation failed: \(reason, privacy: .public) — reconnecting")
        audioCharacteristic = nil
        central?.cancelPeripheralConnection(peripheral)
    }
```

- [ ] **Step 2: didFailToConnect — yield `.connecting` for the pending retry**

Replace the whole `didFailToConnect` method with:

```swift
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        guard peripheral.identifier == targetDeviceID else { return }
        logger.error("connect failed: \(String(describing: error), privacy: .public) — pending retry")
        eventContinuation?.yield(.disconnected)
        eventContinuation?.yield(.connecting)   // parity with didDisconnectPeripheral: a
        central.connect(peripheral)             // pending retry IS connecting (spec §4)
    }
```

- [ ] **Step 3: didDiscoverServices — surface errors and a missing audio service**

Replace the whole `didDiscoverServices` method with:

```swift
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard peripheral.identifier == targetDeviceID else { return }
        if let error {
            retryNegotiation(peripheral, because: "service discovery error: \(error)")
            return
        }
        let services = peripheral.services ?? []
        guard services.contains(where: { $0.uuid == audioServiceUUID }) else {
            retryNegotiation(peripheral, because: "audio service missing from discovery result")
            return
        }
        for service in services {
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
```

- [ ] **Step 4: didDiscoverCharacteristicsFor — surface audio-service failures (battery stays best-effort)**

Replace the whole `didDiscoverCharacteristicsFor` method with:

```swift
    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard peripheral.identifier == targetDeviceID else { return }
        if service.uuid == audioServiceUUID {
            if let error {
                retryNegotiation(peripheral, because: "characteristic discovery error: \(error)")
                return
            }
            let uuids = (service.characteristics ?? []).map(\.uuid)
            guard uuids.contains(CBUUID(string: OmiConstants.codecCharacteristicUUID)),
                  uuids.contains(CBUUID(string: OmiConstants.audioDataCharacteristicUUID)) else {
                retryNegotiation(peripheral, because: "codec/audio characteristic missing")
                return
            }
        }
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
```

- [ ] **Step 5: didUpdateValueFor — surface codec-read errors; log an empty codec value**

Replace the whole `didUpdateValueFor` method with:

```swift
    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral.identifier == targetDeviceID else { return }
        if characteristic.uuid == CBUUID(string: OmiConstants.codecCharacteristicUUID), let error {
            retryNegotiation(peripheral, because: "codec read error: \(error)")
            return
        }
        guard let value = characteristic.value else { return }
        switch characteristic.uuid {
        case CBUUID(string: OmiConstants.codecCharacteristicUUID):
            if value.isEmpty {
                // Spec §4: no known firmware sends this — surfacing beats silence, failing
                // would be speculative. Opus is the documented default on firmware ≥1.0.3.
                logger.error("codec characteristic empty — defaulting to Opus")
            }
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
```

- [ ] **Step 6: Build**

Run: `xcodebuild -project Sotto.xcodeproj -scheme Sotto -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 7: Commit**

```bash
git add Sotto/Omi/CoreBluetoothOmiTransport.swift
git commit -m "fix: surface Omi negotiation errors instead of silently pinning at Connecting"
```

---

### Task 2: Settings device-status honesty

**Files:**
- Modify: `Sotto/App/SettingsView.swift`
- Modify: `Sotto/App/AppModel.swift` (stateTask loop — reset state to nil when a session's stream ends)
- Create: `SottoTests/DeviceStatusLabelTests.swift`

**Interfaces:**
- Produces: `SettingsView.deviceStatusLabel(for state: DeviceConnectionState?) -> String` (internal `static func` — tests and the view body both call it).

- [ ] **Step 1: Write the failing test**

Create `SottoTests/DeviceStatusLabelTests.swift`:

```swift
import Testing
@testable import Sotto

struct DeviceStatusLabelTests {
    @Test func idleAndInSessionDisconnectedAreDistinct() {
        #expect(SettingsView.deviceStatusLabel(for: nil) == "Connects when listening")
        #expect(SettingsView.deviceStatusLabel(for: .disconnected) == "Not connected")
    }

    @Test func sessionStatesMapToLabels() {
        #expect(SettingsView.deviceStatusLabel(for: .connecting) == "Connecting…")
        #expect(SettingsView.deviceStatusLabel(for: .connected) == "Connected")
        #expect(SettingsView.deviceStatusLabel(for: .streaming) == "Streaming")
        #expect(SettingsView.deviceStatusLabel(for: .unavailable(.poweredOff)) == "Bluetooth is off")
        #expect(SettingsView.deviceStatusLabel(for: .unavailable(.unauthorized)) == "Bluetooth permission needed")
        #expect(SettingsView.deviceStatusLabel(for: .unavailable(.unsupported)) == "Bluetooth unavailable")
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `xcodebuild -project Sotto.xcodeproj -scheme Sotto -destination "$DEST" test -only-testing:SottoTests/DeviceStatusLabelTests 2>&1 | tail -8`
Expected: BUILD FAILURE — `type 'SettingsView' has no member 'deviceStatusLabel(for:)'` (a compile failure IS the failing state here).

- [ ] **Step 3: Implement the label function + caption**

In `Sotto/App/SettingsView.swift`, replace the existing `private var deviceStatusLabel: String { ... }` (the whole computed property, currently ~lines 145–155) with:

```swift
    private var deviceStatusLabel: String {
        Self.deviceStatusLabel(for: model.deviceConnectionState)
    }

    /// Redesign spec §4: `nil` means "no session has observed the device" (status is
    /// session-scoped by design, SPEC "Omi Device") — it must not read as a failure.
    /// In-session `.disconnected` is the genuinely-lost case and keeps the scary label.
    /// `nonisolated`: the View protocol's @MainActor inference would otherwise isolate
    /// this pure function and block the non-isolated unit test.
    nonisolated static func deviceStatusLabel(for state: DeviceConnectionState?) -> String {
        switch state {
        case .streaming: "Streaming"
        case .connected: "Connected"
        case .connecting: "Connecting…"
        case .disconnected: "Not connected"
        case nil: "Connects when listening"
        case .unavailable(.poweredOff): "Bluetooth is off"
        case .unavailable(.unauthorized): "Bluetooth permission needed"
        case .unavailable(.unsupported): "Bluetooth unavailable"
        }
    }
```

Then in `deviceSection`, directly under the `LabeledContent("Status", value: deviceStatusLabel)` line, add:

```swift
                Text("Live status appears while Sotto is listening.")
                    .font(.caption).foregroundStyle(.secondary)
```

- [ ] **Step 4: Reset the state to nil when a session ends**

In `Sotto/App/AppModel.swift`, inside `composePipeline`'s `stateTask` loop (the `while !Task.isCancelled` loop over `wearableSource.connectionStates()`, ~line 1007), add a reset between the end of the `for await` loop and the `try? await Task.sleep`:

```swift
                    // Session over (the source's stop() finished this stream): the final
                    // yielded state (.disconnected) described the torn-down session, not
                    // the device. Reset so Settings shows the idle "Connects when
                    // listening" copy instead of a scary "Not connected" (spec §4).
                    await MainActor.run { self?.deviceConnectionState = nil }
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `xcodebuild -project Sotto.xcodeproj -scheme Sotto -destination "$DEST" test -only-testing:SottoTests/DeviceStatusLabelTests 2>&1 | tail -8`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 6: Run the AppModel suite (guards the stateTask change)**

Run: `xcodebuild -project Sotto.xcodeproj -scheme Sotto -destination "$DEST" test -only-testing:SottoTests/AppModelTests 2>&1 | tail -8`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 7: Commit**

```bash
git add Sotto/App/SettingsView.swift Sotto/App/AppModel.swift SottoTests/DeviceStatusLabelTests.swift
git commit -m "feat: distinguish idle from lost in Omi settings status"
```

---

## Phase A — mic-first failover + waiting state

### Task 3: FailoverAudioSource — mic-first, immediate first upgrade, post-failure hysteresis

**Files:**
- Modify: `Sotto/Wearable/FailoverAudioSource.swift` (substantial rewrite of the selection rules; the file's existing diagnostics and concurrency guards are preserved)
- Modify: `SottoTests/FailoverAudioSourceTests.swift` (full rewrite — the startup race no longer exists)

**Interfaces:**
- Consumes: `ConnectableAudioSource`, `AudioSource`, `DeviceConnectionState`, `AudioSourceChange(source:reason:)` — unchanged.
- Produces: `FailoverConfig(reconnectGrace:returnHysteresis:)` — **`startupRace` is deleted**. `FailoverAudioSource.start()` attempts the phone mic inline and **never throws on mic-start failure** (it emits `.captureUnavailable` instead); it still throws `FailoverError.alreadyStarted`. New private state `wearableWasActiveThisSession`; new private helpers `switchToWearable()` / `armReturnTimer()`. Task 4 adds `retryPhoneMic()` on top of `activatePhoneMic`'s new clobber guard (`activeSourceType == expectedSource` re-check), which is introduced HERE because mic-first makes the clobber race common, not rare.

- [ ] **Step 1: Rewrite the selection rules in `FailoverAudioSource.swift`**

Apply these exact changes (everything not listed stays as-is, including the `logger`, `sourceChanges()`, `handleRouteChange()`, `forward`, `emit`, `stop()` except the noted line, and the doc comments):

1. `FailoverConfig` — delete the `startupRace` field:

```swift
struct FailoverConfig: Sendable {
    var reconnectGrace: Duration = .seconds(3)
    var returnHysteresis: Duration = .seconds(10)
}
```

2. Delete the `private var startupTask: Task<Void, Never>?` property, and remove `startupTask` from the cancel loop and nil-outs in `stop()` (the loop becomes `[wearablePumpTask, micPumpTask, stateTask, graceTask, returnTask]`).

3. Below `hasEmittedInitial`, add:

```swift
    /// Spec §1: distinguishes the FIRST `.streaming` of a session (upgrade immediately —
    /// nothing to distrust yet) from a post-failure return (10 s hysteresis). In-memory,
    /// per-session; `hasEmittedInitial` cannot serve — under mic-first the mic sets it
    /// almost immediately every session.
    private var wearableWasActiveThisSession = false
```

4. Replace `start()`'s body after the `outward = continuation` line — the pump/state task creation stays identical, the `startupTask` block is replaced by an inline mic activation:

```swift
    func start() async throws -> AsyncStream<AudioChunk> {
        guard !started else { throw FailoverError.alreadyStarted }
        generation += 1
        started = true
        logger.notice("start: mic-first, \(self.sourceType.displayName, privacy: .public) upgrades when streaming")
        activeSourceType = nil
        hasEmittedInitial = false
        wearableWasActiveThisSession = false
        lastWearableState = .disconnected
        let (stream, continuation) = AsyncStream.makeStream(of: AudioChunk.self)
        outward = continuation

        let states = await wearable.connectionStates()
        let wearableStream = try await wearable.start()
        // Always drain the wearable stream; forward only while the wearable is active
        // (prevents unbounded buffering while on fallback).
        wearablePumpTask = Task { [weak self, sourceType] in
            for await chunk in wearableStream {
                await self?.forward(chunk, from: sourceType)
            }
        }
        stateTask = Task { [weak self] in
            for await state in states {
                await self?.handle(state)
            }
        }
        // Mic-first (redesign spec §1): Start's tap is the only guaranteed-foreground
        // moment, and iOS forbids STARTING capture from the background — so the mic
        // starts NOW, with no timer in between. The wearable upgrades on its first
        // `.streaming`. Never throws: a failed mic start is the first waiting entry
        // (.captureUnavailable), not a failed session.
        await activatePhoneMic(reason: .initial)
        return stream
    }
```

5. Replace `handle(_:)`'s `switch` (the `guard started`, `lastWearableState` mirror, and state log line above it stay):

```swift
        switch state {
        case .streaming:
            graceTask?.cancel(); graceTask = nil
            if activeSourceType == nil {
                // Waiting (or the instant before the inline mic activation lands): rescue
                // immediately — hysteresis never delays recovery from zero capture (spec §1).
                activate(sourceType, reason: .initial)
            } else if activeSourceType == .phoneMic {
                if !wearableWasActiveThisSession {
                    await switchToWearable()          // first evidence: upgrade now
                } else if returnTask == nil {
                    armReturnTimer()                  // already failed once: prove 10 s
                }
            }
        case .disconnected, .unavailable:
            returnTask?.cancel(); returnTask = nil
            if activeSourceType == sourceType, graceTask == nil {
                graceTask = Task { [weak self, config] in
                    try? await Task.sleep(for: config.reconnectGrace)
                    guard !Task.isCancelled else { return }
                    await self?.graceExpired()
                }
            }
        case .connecting, .connected:
            break
        }
```

6. Delete `startupRaceExpired()` entirely. Replace `returnHysteresisElapsed()` and add the two helpers:

```swift
    private func armReturnTimer() {
        returnTask = Task { [weak self, config] in
            try? await Task.sleep(for: config.returnHysteresis)
            guard !Task.isCancelled else { return }
            await self?.returnHysteresisElapsed()
        }
    }

    private func returnHysteresisElapsed() async {
        returnTask = nil
        logger.notice("return hysteresis elapsed, started: \(self.started), active: \(self.activeSourceType?.displayName ?? "none", privacy: .public)")
        guard started, activeSourceType == .phoneMic else { return }
        await switchToWearable()
    }

    /// Stops the mic and hands capture to the wearable — shared by the first-upgrade path
    /// (immediately on `.streaming`) and the post-failure return (after the hysteresis).
    /// Re-checks after the suspended `phoneMic.stop()` (RACE B — see the concurrency notes
    /// above `handle(_:)`): the wearable may have dropped again during the suspension, in
    /// which case the mic is restarted rather than claiming a dead wearable.
    private func switchToWearable() async {
        let gen = generation
        micPumpTask?.cancel(); micPumpTask = nil
        await phoneMic.stop()
        guard generation == gen, started else { return }
        if lastWearableState == .streaming {
            activate(sourceType, reason: .wearableRecovered)
        } else {
            await activatePhoneMic(reason: .wearableDisconnected)
        }
    }
```

7. In `activate(_:reason:)`, add the flag line directly after `activeSourceType = source`:

```swift
        if source == sourceType { wearableWasActiveThisSession = true }
```

8. Replace `activatePhoneMic(reason:)` with the hardened version:

```swift
    private func activatePhoneMic(reason: AudioSourceChangeReason) async {
        let gen = generation
        let expectedSource = activeSourceType
        logger.notice("starting phone mic (reason: \(String(describing: reason), privacy: .public))")
        do {
            let stream = try await phoneMic.start()
            // RACE A + activation clobber (spec §1 hardening): a stop()/restart, OR a
            // wearable activation (handle(.streaming)'s nil branch), may have run while
            // `phoneMic.start()` was suspended above. Undo the orphaned start rather than
            // clobbering the current source. Common under mic-first: a wearable that is
            // already in range can stream during the inline start-up mic activation.
            guard generation == gen, started, activeSourceType == expectedSource else {
                await phoneMic.stop()
                return
            }
            micPumpTask = Task { [weak self] in
                for await chunk in stream {
                    await self?.forward(chunk, from: .phoneMic)
                }
            }
            activate(.phoneMic, reason: reason)
            // The wearable may have STARTED streaming during the suspended mic start while
            // a previous source was still nominally active (grace path) — that `.streaming`
            // edge was consumed and will not re-fire, so arm the return path from the
            // recorded level here.
            if lastWearableState == .streaming, returnTask == nil {
                armReturnTimer()
            }
        } catch {
            logger.error("phone mic start FAILED: \(String(describing: error), privacy: .public)")
            guard generation == gen, started else { return }
            graceTask?.cancel(); graceTask = nil   // no timers run while waiting (spec §1)
            activeSourceType = nil
            emit(AudioSourceChange(source: nil, reason: .captureUnavailable))
        }
    }
```

9. Update the actor's header doc comment: change the sentence mentioning "Timer tasks (startup race / grace / hysteresis)" to "Timer tasks (grace / hysteresis)".

- [ ] **Step 2: Rewrite `SottoTests/FailoverAudioSourceTests.swift`**

Replace the file's entire contents with:

```swift
import Foundation
import Testing
@testable import Sotto

struct FailoverAudioSourceTests {
    private let fastConfig = FailoverConfig(
        reconnectGrace: .milliseconds(80),
        returnHysteresis: .milliseconds(120))
    /// For asserting IMMEDIATE transitions: if the implementation wrongly applied the
    /// hysteresis, the change would take 5 s and the elapsed-time assertion fails.
    private let slowReturnConfig = FailoverConfig(
        reconnectGrace: .milliseconds(80),
        returnHysteresis: .seconds(5))

    private func makeChunk(_ value: Float = 0.5) -> AudioChunk {
        AudioChunk(samples: [Float](repeating: value, count: 4096), hostTime: 1)
    }

    private func collectChanges(_ source: FailoverAudioSource) async -> AsyncStream<AudioSourceChange>.AsyncIterator {
        await source.sourceChanges().makeAsyncIterator()
    }

    @Test func micActivatesImmediatelyOnStart() async throws {
        let omi = FakeConnectableAudioSource()
        let mic = FakeSimpleAudioSource()
        let failover = FailoverAudioSource(wearable: omi, phoneMic: mic, config: fastConfig)
        var changes = await collectChanges(failover)
        let stream = try await failover.start()
        #expect(await changes.next() == AudioSourceChange(source: .phoneMic, reason: .initial))
        #expect(await mic.startCount == 1)
        await mic.emitChunk(makeChunk())
        var it = stream.makeAsyncIterator()
        #expect(await it.next()?.samples.count == 4096)
        await failover.stop()
    }

    @Test func startWithThrowingMicEntersWaitingWithoutThrowing() async throws {
        struct Boom: Error {}
        let omi = FakeConnectableAudioSource()
        let mic = FakeSimpleAudioSource()
        await mic.setStartError(Boom())
        let failover = FailoverAudioSource(wearable: omi, phoneMic: mic, config: fastConfig)
        var changes = await collectChanges(failover)
        _ = try await failover.start()   // must NOT throw (spec §1)
        #expect(await changes.next() == AudioSourceChange(source: nil, reason: .captureUnavailable))
        #expect(await failover.activeSourceType == nil)
        #expect(await omi.startCount == 1)   // the wearable side stays armed
        await failover.stop()
    }

    @Test func firstStreamingUpgradesImmediately() async throws {
        let omi = FakeConnectableAudioSource()
        let mic = FakeSimpleAudioSource()
        let failover = FailoverAudioSource(wearable: omi, phoneMic: mic, config: slowReturnConfig)
        var changes = await collectChanges(failover)
        _ = try await failover.start()
        #expect(await changes.next()?.source == .phoneMic)
        let clock = ContinuousClock()
        let t0 = clock.now
        await omi.setState(.streaming)
        #expect(await changes.next() == AudioSourceChange(source: .omi, reason: .wearableRecovered))
        #expect(clock.now - t0 < .seconds(1))   // immediate, not the 5 s hysteresis
        #expect(await mic.stopCount >= 1)
        await failover.stop()
    }

    @Test func rescueFromWaitingIsImmediate() async throws {
        struct Boom: Error {}
        let omi = FakeConnectableAudioSource()
        let mic = FakeSimpleAudioSource()
        await mic.setStartError(Boom())
        let failover = FailoverAudioSource(wearable: omi, phoneMic: mic, config: slowReturnConfig)
        var changes = await collectChanges(failover)
        _ = try await failover.start()
        #expect(await changes.next()?.reason == .captureUnavailable)
        let clock = ContinuousClock()
        let t0 = clock.now
        await omi.setState(.streaming)
        #expect(await changes.next() == AudioSourceChange(source: .omi, reason: .initial))
        #expect(clock.now - t0 < .seconds(1))   // hysteresis never delays zero-capture rescue
        await failover.stop()
    }

    @Test func postFailureReturnWaitsHysteresis() async throws {
        let omi = FakeConnectableAudioSource()
        let mic = FakeSimpleAudioSource()
        let failover = FailoverAudioSource(wearable: omi, phoneMic: mic, config: fastConfig)
        var changes = await collectChanges(failover)
        _ = try await failover.start()
        #expect(await changes.next()?.source == .phoneMic)      // mic-first
        await omi.setState(.streaming)
        #expect(await changes.next()?.source == .omi)           // first upgrade, immediate
        await omi.setState(.disconnected)
        #expect(await changes.next() == AudioSourceChange(source: .phoneMic, reason: .wearableDisconnected))
        await omi.setState(.streaming)                          // returned after a failure
        try await Task.sleep(for: .milliseconds(30))            // < 120 ms hysteresis
        #expect(await failover.activeSourceType == .phoneMic)   // still proving itself
        #expect(await changes.next() == AudioSourceChange(source: .omi, reason: .wearableRecovered))
        await failover.stop()
    }

    @Test func blipWithinGraceDoesNotSwitch() async throws {
        // Widened window (M12 final review Important #3 precedent): 300 ms grace with the
        // blip at 50 ms — comfortably inside, immune to scheduler load.
        let config = FailoverConfig(
            reconnectGrace: .milliseconds(300), returnHysteresis: .milliseconds(300))
        let omi = FakeConnectableAudioSource()
        let mic = FakeSimpleAudioSource()
        let failover = FailoverAudioSource(wearable: omi, phoneMic: mic, config: config)
        var changes = await collectChanges(failover)
        _ = try await failover.start()
        #expect(await changes.next()?.source == .phoneMic)
        await omi.setState(.streaming)
        #expect(await changes.next()?.source == .omi)
        await omi.setState(.disconnected)
        try await Task.sleep(for: .milliseconds(50))     // well inside the 300 ms grace
        await omi.setState(.streaming)
        try await Task.sleep(for: .milliseconds(350))    // past the grace duration
        #expect(await mic.startCount == 1)               // never re-fell-back (1 = mic-first start)
        #expect(await failover.activeSourceType == .omi)
        await failover.stop()
    }

    @Test func flapDuringHysteresisCancelsReturn() async throws {
        let omi = FakeConnectableAudioSource()
        let mic = FakeSimpleAudioSource()
        let failover = FailoverAudioSource(wearable: omi, phoneMic: mic, config: fastConfig)
        var changes = await collectChanges(failover)
        _ = try await failover.start()
        #expect(await changes.next()?.source == .phoneMic)
        await omi.setState(.streaming)
        #expect(await changes.next()?.source == .omi)           // first upgrade
        await omi.setState(.disconnected)
        #expect(await changes.next()?.source == .phoneMic)      // grace expired → mic
        await omi.setState(.streaming)
        try await Task.sleep(for: .milliseconds(30))            // < 120 ms hysteresis
        await omi.setState(.disconnected)                       // flap: cancels the return
        try await Task.sleep(for: .milliseconds(250))
        #expect(await failover.activeSourceType == .phoneMic)
        await failover.stop()
    }

    @Test func stopDuringDelayedMicStartLeavesNoOrphanCapture() async throws {
        let omi = FakeConnectableAudioSource()
        let mic = FakeSimpleAudioSource()
        await mic.setStartDelay(150)
        let failover = FailoverAudioSource(wearable: omi, phoneMic: mic, config: fastConfig)
        let startTask = Task { _ = try await failover.start() }
        try await Task.sleep(for: .milliseconds(50))    // inside the suspended inline mic start
        await failover.stop()
        _ = try? await startTask.value
        try await Task.sleep(for: .milliseconds(250))
        #expect(await mic.stopCount >= 1)               // orphaned start undone (RACE A)
        #expect(await failover.activeSourceType == nil)
    }

    @Test func omiDropDuringDelayedMicStopRestartsMic() async throws {
        let omi = FakeConnectableAudioSource()
        let mic = FakeSimpleAudioSource()
        let failover = FailoverAudioSource(wearable: omi, phoneMic: mic, config: fastConfig)
        var changes = await collectChanges(failover)
        _ = try await failover.start()
        #expect(await changes.next()?.source == .phoneMic)
        await mic.setStopDelay(100)
        await omi.setState(.streaming)                  // first upgrade suspends on mic.stop()
        try await Task.sleep(for: .milliseconds(30))
        await omi.setState(.disconnected)               // drops during the suspension (RACE B)
        let change = await changes.next()
        #expect(change?.source == .phoneMic)            // mic restarted, not a dead-omi claim
        #expect(await failover.activeSourceType == .phoneMic)
        await failover.stop()
    }

    @Test func stopContractHolds() async throws {
        let omi = FakeConnectableAudioSource()
        let mic = FakeSimpleAudioSource()
        let failover = FailoverAudioSource(wearable: omi, phoneMic: mic, config: fastConfig)
        let stream = try await failover.start()
        await failover.stop()
        await failover.stop()   // idempotent
        var it = stream.makeAsyncIterator()
        #expect(await it.next() == nil)   // stream finished on stop
    }
}
```

- [ ] **Step 3: Run the suite; expect the rewritten tests to pass**

Run: `xcodebuild -project Sotto.xcodeproj -scheme Sotto -destination "$DEST" test -only-testing:SottoTests/FailoverAudioSourceTests 2>&1 | tail -8`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 4: Update `SottoTests/ListeningPipelineSourceTests.swift` for mic-first**

Four exact edits:

1. The suite's shared config (~line 10) — drop `startupRace`:

```swift
    private let fastConfig = FailoverConfig(
        reconnectGrace: .milliseconds(60),
        returnHysteresis: .milliseconds(80))
```

2. The other inline `FailoverConfig(startupRace: .milliseconds(60), reconnectGrace: .milliseconds(60), ...)` (~line 148) — delete its `startupRace:` argument the same way.

3. `captureUnavailableNotifiesLoudly`: the test sets the mic error BEFORE `pipeline.start()`, which under mic-first fires `.captureUnavailable` at start (a first gap) before the omi rescue — changing the count semantics. Preserve the test's intent (ONE loud notify on mid-session capture death) by moving the error injection to after the omi is active. Replace the test body with:

```swift
    @Test func captureUnavailableNotifiesLoudly() async throws {
        struct Boom: Error {}
        let omi = FakeConnectableAudioSource()
        let mic = FakeSimpleAudioSource()
        let failover = FailoverAudioSource(wearable: omi, phoneMic: mic, config: fastConfig)
        let notifications = FakeNotificationScheduler()
        let pipeline = ListeningPipeline(source: failover, recorder: FakeRecorder(),
                                         notifications: notifications)
        await pipeline.start()                       // mic-first: mic activates at start
        await omi.setState(.streaming)               // first upgrade → omi active
        try await Task.sleep(for: .milliseconds(60))
        await mic.setStartError(Boom())              // NOW the fallback will fail
        await omi.setState(.disconnected)            // grace → mic fails → waiting
        try await Task.sleep(for: .milliseconds(300))
        #expect(await notifications.captureUnavailableCount == 1)
        #expect(pipeline.activeSourceType == nil)
        await pipeline.stop()
    }
```

4. `coldStartCaptureUnavailableNotifiesLoudly`: the scenario is unchanged (mic throws at start, omi silent), but there is no race to wait out anymore — update the stale comment and shorten the sleep. Replace the comment block and sleep inside the test with:

```swift
        await pipeline.start()
        // Mic-first: phoneMic.start() throws inline during start(), so captureUnavailable
        // is the pipeline's first-ever source event — no race delay to wait out.
        try await Task.sleep(for: .milliseconds(100))
```

(the `#expect` lines stay unchanged).

- [ ] **Step 5: Run the neighboring suites that construct FailoverAudioSource**

Run: `xcodebuild -project Sotto.xcodeproj -scheme Sotto -destination "$DEST" test -only-testing:SottoTests/ListeningPipelineSourceTests -only-testing:SottoTests/ListeningPipelineTests -only-testing:SottoTests/AppModelTests 2>&1 | tail -8`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 6: Commit**

```bash
git add Sotto/Wearable/FailoverAudioSource.swift SottoTests/FailoverAudioSourceTests.swift SottoTests/ListeningPipelineSourceTests.swift
git commit -m "feat: mic-first failover — phone mic starts at tap, wearable upgrades on first stream"
```

---

### Task 4: `retryPhoneMic()` — the missing recovery rule

**Files:**
- Modify: `Sotto/Wearable/FailoverAudioSource.swift`
- Modify: `SottoTests/FailoverAudioSourceTests.swift` (append tests)

**Interfaces:**
- Produces: `SourceSwitchingAudioSource` protocol gains `func retryPhoneMic() async`; `FailoverAudioSource.retryPhoneMic()` — no-op unless `started && activeSourceType == nil`; routed through the hardened `activatePhoneMic` (Task 3's clobber guard applies). Task 6's `ListeningPipeline.retryCaptureIfWaiting()` calls this through the protocol.

- [ ] **Step 1: Write the failing tests (append to `FailoverAudioSourceTests.swift`)**

```swift
    @Test func retryPhoneMicActivatesFromWaiting() async throws {
        struct Boom: Error {}
        let omi = FakeConnectableAudioSource()
        let mic = FakeSimpleAudioSource()
        await mic.setStartError(Boom())
        let failover = FailoverAudioSource(wearable: omi, phoneMic: mic, config: fastConfig)
        var changes = await collectChanges(failover)
        _ = try await failover.start()
        #expect(await changes.next()?.reason == .captureUnavailable)
        await mic.setStartError(nil)                   // the foreground made the mic legal again
        await failover.retryPhoneMic()
        #expect(await changes.next() == AudioSourceChange(source: .phoneMic, reason: .initial))
        #expect(await failover.activeSourceType == .phoneMic)
        await failover.stop()
    }

    @Test func retryPhoneMicNoOpsWhenSourceActiveOrStopped() async throws {
        let omi = FakeConnectableAudioSource()
        let mic = FakeSimpleAudioSource()
        let failover = FailoverAudioSource(wearable: omi, phoneMic: mic, config: fastConfig)
        var changes = await collectChanges(failover)
        _ = try await failover.start()
        #expect(await changes.next()?.source == .phoneMic)
        await failover.retryPhoneMic()                 // active source → no-op
        #expect(await mic.startCount == 1)
        await failover.stop()
        await failover.retryPhoneMic()                 // stopped → no-op
        #expect(await mic.startCount == 1)
    }

    @Test func retryRacingStreamingLeavesWearableActive() async throws {
        struct Boom: Error {}
        let omi = FakeConnectableAudioSource()
        let mic = FakeSimpleAudioSource()
        await mic.setStartError(Boom())
        let failover = FailoverAudioSource(wearable: omi, phoneMic: mic, config: fastConfig)
        var changes = await collectChanges(failover)
        _ = try await failover.start()
        #expect(await changes.next()?.reason == .captureUnavailable)
        await mic.setStartError(nil)
        await mic.setStartDelay(100)                   // suspend the retry mid-start
        let retryTask = Task { await failover.retryPhoneMic() }
        try await Task.sleep(for: .milliseconds(30))
        await omi.setState(.streaming)                 // rescue wins during the suspension
        #expect(await changes.next()?.source == .omi)
        await retryTask.value
        try await Task.sleep(for: .milliseconds(250))
        #expect(await failover.activeSourceType == .omi)   // retry undone, no clobber
        #expect(await mic.stopCount >= 1)                  // orphaned mic start stopped
        await failover.stop()
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild -project Sotto.xcodeproj -scheme Sotto -destination "$DEST" test -only-testing:SottoTests/FailoverAudioSourceTests 2>&1 | tail -8`
Expected: BUILD FAILURE — `value of type 'FailoverAudioSource' has no member 'retryPhoneMic'`.

- [ ] **Step 3: Implement**

In `Sotto/Wearable/FailoverAudioSource.swift`:

1. Add to the `SourceSwitchingAudioSource` protocol:

```swift
    /// Redesign spec §1: re-attempt phone-mic activation after a `.captureUnavailable`
    /// gap. No-op unless started with nothing capturing. Invoked (via ListeningPipeline)
    /// once per app-foreground transition — never in a loop.
    func retryPhoneMic() async
```

2. Add to the actor (below `handleRouteChange()`):

```swift
    /// Spec §1: routed through the hardened `activatePhoneMic`, so a wearable that
    /// activates during the awaited mic start wins and the orphaned start is undone.
    func retryPhoneMic() async {
        guard started, activeSourceType == nil else { return }
        logger.notice("retrying phone mic (foreground)")
        await activatePhoneMic(reason: .initial)
    }
```

- [ ] **Step 4: Run to verify pass**

Run: `xcodebuild -project Sotto.xcodeproj -scheme Sotto -destination "$DEST" test -only-testing:SottoTests/FailoverAudioSourceTests 2>&1 | tail -8`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add Sotto/Wearable/FailoverAudioSource.swift SottoTests/FailoverAudioSourceTests.swift
git commit -m "feat: retry the phone mic from waiting via retryPhoneMic"
```

---

### Task 5: Waiting-state vocabulary — Live Activity phase + header state

**Files:**
- Modify: `Sotto/LiveActivity/SottoActivityAttributes.swift`
- Modify: `SottoWidgets/SottoWidgetsBundle.swift`
- Modify: `Sotto/App/HeroCard.swift` (`HeaderState` + subtitle rendering)
- Modify: `SottoTests/HeaderStateTests.swift` (append tests)

**Interfaces:**
- Produces: `SottoActivityAttributes.Phase.waiting` (raw value `"waiting"`, additive to the wire format); `HeaderState.waiting(sessionStart: Date?)`; `HeaderState.init(segmentStart:status:haltReason:sessionStart:waiting:)` where `waiting: Bool = false` (default keeps existing call sites compiling — Task 6 passes the real value).

- [ ] **Step 1: Write the failing tests (append to `HeaderStateTests.swift`)**

```swift
    @Test func waitingDerivesOnlyForRunningStatuses() {
        let sessionStart = Date(timeIntervalSince1970: 5)
        for status in [ListeningPipeline.Status.listening, .recording, .silence] {
            #expect(HeaderState(segmentStart: nil, status: status, haltReason: nil,
                                sessionStart: sessionStart, waiting: true)
                == .waiting(sessionStart: sessionStart))
        }
        // Paused/interrupted/idle keep their own states — they already say capture stopped.
        #expect(HeaderState(segmentStart: nil, status: .interrupted, haltReason: .userPause,
                            sessionStart: nil, waiting: true) == .interrupted(.userPause))
        #expect(HeaderState(segmentStart: nil, status: .idle, haltReason: nil,
                            sessionStart: nil, waiting: true) == .idle)
    }

    @Test func waitingTakesPriorityOverStaleSegment() {
        // Capture is dead — a leftover segment date must not keep a live "Recording…" up.
        let state = HeaderState(segmentStart: Date(timeIntervalSince1970: 100),
                                status: .listening, haltReason: nil,
                                sessionStart: nil, waiting: true)
        #expect(state == .waiting(sessionStart: nil))
    }

    @Test func waitingRendering() {
        #expect(HeaderState.waiting(sessionStart: nil).label == "Waiting")
        #expect(HeaderState.waiting(sessionStart: nil).timerStart == nil)
        #expect(HeaderState.waiting(sessionStart: nil).subtitle == nil)   // HeroCard supplies device-aware copy
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild -project Sotto.xcodeproj -scheme Sotto -destination "$DEST" test -only-testing:SottoTests/HeaderStateTests 2>&1 | tail -8`
Expected: BUILD FAILURE — `extra argument 'waiting' in call` / `type 'HeaderState' has no member 'waiting'`.

- [ ] **Step 3: Implement `HeaderState.waiting`**

In `Sotto/App/HeroCard.swift`:

1. Add the case to the enum: `case waiting(sessionStart: Date?)` (after `listening`).
2. Replace the initializer:

```swift
    init(
        segmentStart: Date?,
        status: ListeningPipeline.Status,
        haltReason: ListeningPipeline.HaltReason?,
        sessionStart: Date?,
        waiting: Bool = false
    ) {
        // Waiting first (spec §2): it derives only for statuses that would otherwise
        // falsely claim capture, and it outranks a stale open-segment date — capture is
        // dead, so a pulsing "Recording…" would be a lie.
        if waiting, status == .listening || status == .recording || status == .silence {
            self = .waiting(sessionStart: sessionStart)
        } else if let segmentStart {
            self = .segmentOpen(start: segmentStart)
        } else {
            switch status {
            case .idle: self = .idle
            case .starting: self = .starting
            case .interrupted: self = .interrupted(haltReason)
            case .listening, .recording, .silence:
                self = .listening(sessionStart: sessionStart)
            }
        }
    }
```

3. Extend the derived properties — `label`: add `case .waiting: "Waiting"`; `dotColor`: add `case .waiting: .orange`; `timerStart`: add `.waiting` to the nil branch (`case .idle, .starting, .interrupted, .waiting: nil`); `subtitle` unchanged (returns nil for waiting — HeroCard renders device-aware copy).

4. In `HeroCard`'s `subtitleLine`, add a waiting branch BEFORE the timer branch:

```swift
    @ViewBuilder private var subtitleLine: some View {
        if case .waiting = state {
            Text("Can't record right now — waiting for \(model.pairedDeviceKind?.displayName ?? "your device") or the iPhone mic.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.leading, 22)
        } else if let timerStart = state.timerStart {
            Text(timerStart, style: .timer)
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.leading, 22)
        } else if let subtitle = state.subtitle {
            Text(subtitle)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.leading, 22)
        }
    }
```

- [ ] **Step 4: Implement `Phase.waiting` + widget rendering**

In `Sotto/LiveActivity/SottoActivityAttributes.swift`, extend the enum: `case listening, recording, pausedByUser, pausedBySystem, waiting` (`isPaused` unchanged — waiting is not paused; the Live Activity button keeps offering "Pause").

In `SottoWidgets/SottoWidgetsBundle.swift`, add to each switch in the `Phase` extension:
- `label`: `case .waiting: "Waiting"`
- `tint`: `case .waiting: .orange`
- `glyph`: `case .waiting: "hourglass"`
- `compactGlyph`: `case .waiting: "hourglass"`

- [ ] **Step 5: Run to verify pass**

Run: `xcodebuild -project Sotto.xcodeproj -scheme Sotto -destination "$DEST" test -only-testing:SottoTests/HeaderStateTests 2>&1 | tail -8`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 6: Commit**

```bash
git add Sotto/LiveActivity/SottoActivityAttributes.swift SottoWidgets/SottoWidgetsBundle.swift Sotto/App/HeroCard.swift SottoTests/HeaderStateTests.swift
git commit -m "feat: waiting state vocabulary for header and Live Activity"
```

---

### Task 6: Pipeline waiting state, notification lifecycle, foreground retry

**Files:**
- Modify: `Sotto/Pipeline/ListeningPipeline.swift`
- Modify: `Sotto/Notifications/NotificationScheduling.swift`
- Modify: `Sotto/App/HeroCard.swift` (pass the waiting flag)
- Modify: `Sotto/App/ContentView.swift` (scenePhase hook)
- Modify: `SottoTests/Fakes.swift` (scheduler fake signatures)
- Modify: `SottoTests/ListeningPipelineSourceTests.swift` (append tests)

**Interfaces:**
- Consumes: `SourceSwitchingAudioSource.retryPhoneMic()` (Task 4); `HeaderState.init(...waiting:)` and `Phase.waiting` (Task 5); `RecorderStateMachine.rollover(to:)` (existing).
- Produces: `ListeningPipeline.isWaitingForCapture: Bool` (derived); `ListeningPipeline.retryCaptureIfWaiting() async`; `ListeningPipeline.waitingNotificationDelay: TimeInterval = 30` (the one named constant); `NotificationScheduling.scheduleCaptureUnavailableNotification(deviceName:delay:)` and `cancelCaptureUnavailableNotification()`.

- [ ] **Step 1: Write the failing tests (append to `SottoTests/ListeningPipelineSourceTests.swift`)**

```swift
    @Test func captureUnavailableDerivesWaitingAndSchedulesDelayedNotification() async throws {
        struct Boom: Error {}
        let omi = FakeConnectableAudioSource()
        let mic = FakeSimpleAudioSource()
        await mic.setStartError(Boom())
        let failover = FailoverAudioSource(
            wearable: omi, phoneMic: mic,
            config: FailoverConfig(reconnectGrace: .milliseconds(80), returnHysteresis: .milliseconds(120)))
        let recorder = FakeRecorder()
        let scheduler = FakeNotificationScheduler()
        let pipeline = ListeningPipeline(source: failover, recorder: recorder, notifications: scheduler)
        await pipeline.start()
        try await Task.sleep(for: .milliseconds(150))    // let the captureUnavailable event land
        #expect(pipeline.status == .listening)           // session alive
        #expect(pipeline.isWaitingForCapture)
        #expect(await scheduler.captureUnavailableDelays == [ListeningPipeline.waitingNotificationDelay])
        await pipeline.stop()
    }

    @Test func captureUnavailableAfterActiveSourceFinalizesViaRollover() async throws {
        struct Boom: Error {}
        let omi = FakeConnectableAudioSource()
        let mic = FakeSimpleAudioSource()
        let failover = FailoverAudioSource(
            wearable: omi, phoneMic: mic,
            config: FailoverConfig(reconnectGrace: .milliseconds(80), returnHysteresis: .milliseconds(120)))
        let recorder = FakeRecorder()
        let scheduler = FakeNotificationScheduler()
        let pipeline = ListeningPipeline(source: failover, recorder: recorder, notifications: scheduler)
        await pipeline.start()
        try await Task.sleep(for: .milliseconds(100))    // mic-first activation lands
        await omi.setState(.streaming)                   // upgrade to omi
        try await Task.sleep(for: .milliseconds(100))
        await mic.setStartError(Boom())                  // next fallback will fail
        await omi.setState(.disconnected)                // grace → mic fails → waiting
        try await Task.sleep(for: .milliseconds(400))
        #expect(pipeline.isWaitingForCapture)
        // The rollover finalizing the dead-capture segment carried the LAST live source.
        #expect(await recorder.rolloverCalls.last == .omi)
        await pipeline.stop()
    }

    @Test func retryRestoresCaptureAndCancelsNotification() async throws {
        struct Boom: Error {}
        let omi = FakeConnectableAudioSource()
        let mic = FakeSimpleAudioSource()
        await mic.setStartError(Boom())
        let failover = FailoverAudioSource(
            wearable: omi, phoneMic: mic,
            config: FailoverConfig(reconnectGrace: .milliseconds(80), returnHysteresis: .milliseconds(120)))
        let recorder = FakeRecorder()
        let scheduler = FakeNotificationScheduler()
        let pipeline = ListeningPipeline(source: failover, recorder: recorder, notifications: scheduler)
        await pipeline.start()
        try await Task.sleep(for: .milliseconds(150))
        #expect(pipeline.isWaitingForCapture)
        await mic.setStartError(nil)                     // foreground made the mic legal
        await pipeline.retryCaptureIfWaiting()
        try await Task.sleep(for: .milliseconds(150))
        #expect(!pipeline.isWaitingForCapture)
        #expect(pipeline.activeSourceType == .phoneMic)
        #expect(await scheduler.captureUnavailableCancelCount >= 1)
        await pipeline.stop()
    }

    @Test func failedRetryDoesNotRearmNotification() async throws {
        struct Boom: Error {}
        let omi = FakeConnectableAudioSource()
        let mic = FakeSimpleAudioSource()
        await mic.setStartError(Boom())
        let failover = FailoverAudioSource(
            wearable: omi, phoneMic: mic,
            config: FailoverConfig(reconnectGrace: .milliseconds(80), returnHysteresis: .milliseconds(120)))
        let recorder = FakeRecorder()
        let scheduler = FakeNotificationScheduler()
        let pipeline = ListeningPipeline(source: failover, recorder: recorder, notifications: scheduler)
        await pipeline.start()
        try await Task.sleep(for: .milliseconds(150))
        #expect(await scheduler.captureUnavailableDelays.count == 1)
        await pipeline.retryCaptureIfWaiting()           // mic still throwing
        try await Task.sleep(for: .milliseconds(150))
        #expect(await scheduler.captureUnavailableDelays.count == 1)   // not a new waiting entry
        await pipeline.stop()
    }

    @Test func stopWhileWaitingCancelsNotification() async throws {
        struct Boom: Error {}
        let omi = FakeConnectableAudioSource()
        let mic = FakeSimpleAudioSource()
        await mic.setStartError(Boom())
        let failover = FailoverAudioSource(
            wearable: omi, phoneMic: mic,
            config: FailoverConfig(reconnectGrace: .milliseconds(80), returnHysteresis: .milliseconds(120)))
        let recorder = FakeRecorder()
        let scheduler = FakeNotificationScheduler()
        let pipeline = ListeningPipeline(source: failover, recorder: recorder, notifications: scheduler)
        await pipeline.start()
        try await Task.sleep(for: .milliseconds(150))
        await pipeline.stop()                            // deliberate stop at t+ε
        #expect(await scheduler.captureUnavailableCancelCount >= 1)   // no loud lie 30 s later
    }

    @Test func liveActivityMirrorsWaiting() async throws {
        struct Boom: Error {}
        let omi = FakeConnectableAudioSource()
        let mic = FakeSimpleAudioSource()
        await mic.setStartError(Boom())
        let failover = FailoverAudioSource(
            wearable: omi, phoneMic: mic,
            config: FailoverConfig(reconnectGrace: .milliseconds(80), returnHysteresis: .milliseconds(120)))
        let recorder = FakeRecorder()
        let activity = FakeLiveActivityController()
        let pipeline = ListeningPipeline(
            source: failover, recorder: recorder, liveActivity: activity)
        await pipeline.start()
        try await Task.sleep(for: .milliseconds(150))
        #expect(activity.updates.last?.phase == .waiting)
        await pipeline.stop()
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild -project Sotto.xcodeproj -scheme Sotto -destination "$DEST" test -only-testing:SottoTests/ListeningPipelineSourceTests 2>&1 | tail -8`
Expected: BUILD FAILURE — missing `isWaitingForCapture`, `retryCaptureIfWaiting`, `captureUnavailableDelays`, etc.

- [ ] **Step 3: Update `NotificationScheduling` + `UserNotificationScheduler`**

In `Sotto/Notifications/NotificationScheduling.swift`:

1. Protocol — replace the capture-unavailable requirement with two:

```swift
    /// M12 → redesign spec §3: the wearable is gone AND the iPhone mic could not start —
    /// nothing is capturing. Scheduled with `delay` (30 s: only persistent gaps alert)
    /// and cancelled by `cancelCaptureUnavailableNotification` on recovery or stop.
    func scheduleCaptureUnavailableNotification(deviceName: String, delay: TimeInterval) async
    func cancelCaptureUnavailableNotification() async
```

2. `requestAuthorizationIfNeeded` — full authorization (spec decision 5):

```swift
    func requestAuthorizationIfNeeded() async {
        // Full [.alert, .sound], not provisional (redesign spec §3): the "Recording
        // stopped" alert must always deliver loudly; provisional-quiet delivery is why
        // it was historically missed. Called from the foreground only (pipeline gates).
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])
    }
```

3. Replace the schedule implementation and add the cancel:

```swift
    func scheduleCaptureUnavailableNotification(deviceName: String, delay: TimeInterval) async {
        let content = UNMutableNotificationContent()
        content.title = "Recording stopped"
        content.body = "The \(deviceName) disconnected and the iPhone microphone could not start. Open Sotto to resume."
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: Self.captureUnavailableIdentifier, content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false))
        try? await UNUserNotificationCenter.current().add(request)
    }

    func cancelCaptureUnavailableNotification() async {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.captureUnavailableIdentifier])
        center.removeDeliveredNotifications(withIdentifiers: [Self.captureUnavailableIdentifier])
    }
```

- [ ] **Step 4: Update the fakes**

In `SottoTests/Fakes.swift`:

1. `FakeNotificationScheduler` — replace the capture-unavailable members:

```swift
    private(set) var captureUnavailableDelays: [TimeInterval] = []
    private(set) var captureUnavailableCancelCount = 0
    func scheduleCaptureUnavailableNotification(deviceName: String, delay: TimeInterval) {
        captureUnavailableDelays.append(delay)
    }
    func cancelCaptureUnavailableNotification() { captureUnavailableCancelCount += 1 }
```

(Remove the old `captureUnavailableCount` property and its single-parameter method. Exactly two existing assertions reference it, both in `SottoTests/ListeningPipelineSourceTests.swift` — in `captureUnavailableNotifiesLoudly` and `coldStartCaptureUnavailableNotifiesLoudly`; change each `#expect(await notifications.captureUnavailableCount == 1)` to `#expect(await notifications.captureUnavailableDelays.count == 1)`.)

2. `GatedNotificationScheduler` — update the two signatures:

```swift
    func scheduleCaptureUnavailableNotification(deviceName: String, delay: TimeInterval) {}
    func cancelCaptureUnavailableNotification() {}
```

- [ ] **Step 5: Implement the pipeline changes**

In `Sotto/Pipeline/ListeningPipeline.swift`:

1. Add below the `Status` enum:

```swift
    /// Spec §3: the one tunable place for the waiting-notification delay.
    static let waitingNotificationDelay: TimeInterval = 30
```

2. Add below `activeSourceType`:

```swift
    /// Spec §2: the session claims to run but nothing is capturing — the waiting state.
    /// Derived, never persisted. Only a switching (wearable-paired) source can wait: a
    /// plain phone-mic session parks via existing paths when its mic dies.
    var isWaitingForCapture: Bool {
        source is any SourceSwitchingAudioSource && activeSourceType == nil
            && (status == .listening || status == .recording || status == .silence)
    }
```

3. In `start()`, replace `await notifications?.requestAuthorizationIfNeeded()` with:

```swift
            // Spec §3: the authorization prompt only exists in the foreground; a cold
            // background start defers it to the next foreground session start.
            if UIApplication.shared.applicationState == .active {
                await notifications?.requestAuthorizationIfNeeded()
            }
```

4. In `handleSourceChange`, replace the `.captureUnavailable` case:

```swift
        case .captureUnavailable:
            let previous = activeSourceType
            activeSourceType = nil
            if let previous {
                // Finalize any open segment (spec §2): the captured audio belongs to the
                // source that captured it, and the header must not keep a live
                // "Recording…" over dead capture.
                let snapshot = await recorder.rollover(to: previous)
                apply(snapshot)
            }
            if !hasNotifiedCaptureUnavailable {
                hasNotifiedCaptureUnavailable = true
                log("Nothing capturing — waiting for \(source.sourceType.displayName) or the iPhone mic")
                await notifications?.scheduleCaptureUnavailableNotification(
                    deviceName: source.sourceType.displayName,
                    delay: Self.waitingNotificationDelay)
            }
```

5. In the `.initial`, `.wearableDisconnected`, and `.wearableRecovered` cases, directly after each `hasNotifiedCaptureUnavailable = false` line, add:

```swift
            await notifications?.cancelCaptureUnavailableNotification()
```

6. In the `.wearableRecovered` case, replace the log line (a rescue can now recover to the MIC, not just the wearable — "Omi reconnected" would be a lie there):

```swift
            if previousSource != source {
                log(source == self.source.sourceType
                    ? "\(source.displayName) connected"
                    : "Capturing via \(source.displayName)")
            }
```

7. In `performHalt`, add to BOTH the `.stop` and `.park` cases (next to the existing notification calls):

```swift
            await notifications?.cancelCaptureUnavailableNotification()
```

In the `.park` case ONLY, also add (the `.stop` case already resets it):

```swift
            // Re-arm across a park: a resumed session that hits a NEW gap is a new waiting
            // entry and must be able to notify again (spec §3 re-arm semantics).
            hasNotifiedCaptureUnavailable = false
```

8. Replace `activityPhase(for:)`:

```swift
    func activityPhase(for status: Status) -> SottoActivityAttributes.Phase? {
        switch status {
        case .idle, .starting: nil
        case .listening, .silence: isWaitingForCapture ? .waiting : .listening
        case .recording: isWaitingForCapture ? .waiting : .recording
        case .interrupted: haltReason == .userPause ? .pausedByUser : .pausedBySystem
        }
    }
```

9. Add the retry entry point (below `toggleFromIntent()`):

```swift
    /// Spec §2 foreground retry hook: called on scenePhase .active — once per transition,
    /// never in a loop. Skips paused/interrupted (their recovery is the resume path).
    func retryCaptureIfWaiting() async {
        guard isWaitingForCapture,
              let switching = source as? any SourceSwitchingAudioSource else { return }
        await switching.retryPhoneMic()
    }
```

- [ ] **Step 6: Wire the UI**

1. `Sotto/App/HeroCard.swift` — in the `state` computed property, pass the flag:

```swift
    private var state: HeaderState {
        HeaderState(
            segmentStart: pipeline.currentSegmentStartDate,
            status: pipeline.status,
            haltReason: pipeline.haltReason,
            sessionStart: pipeline.sessionStartedAt,
            waiting: pipeline.isWaitingForCapture)
    }
```

2. `Sotto/App/ContentView.swift` — in the `.onChange(of: scenePhase)` block, after the existing two `Task { ... }` lines, add:

```swift
            // Redesign spec §2: the mic cannot START in the background, so a waiting
            // session retries capture the moment the app is foreground again. Once per
            // transition — onChange fires once per phase change.
            Task { await model.pipeline?.retryCaptureIfWaiting() }
```

- [ ] **Step 7: Run the new tests + neighbors**

Run: `xcodebuild -project Sotto.xcodeproj -scheme Sotto -destination "$DEST" test -only-testing:SottoTests/ListeningPipelineSourceTests -only-testing:SottoTests/ListeningPipelineTests -only-testing:SottoTests/LiveActivityWiringTests -only-testing:SottoTests/HeaderStateTests 2>&1 | tail -8`
Expected: `** TEST SUCCEEDED **`. If `LiveActivityWiringTests` or other suites break on the fake-scheduler signature change, update those call sites to the new `captureUnavailableDelays` API — semantics are per-gap, unchanged.

- [ ] **Step 8: Commit**

```bash
git add Sotto/Pipeline/ListeningPipeline.swift Sotto/Notifications/NotificationScheduling.swift Sotto/App/HeroCard.swift Sotto/App/ContentView.swift SottoTests/Fakes.swift SottoTests/ListeningPipelineSourceTests.swift
git commit -m "feat: waiting state — honest UI, delayed loud notification, foreground retry"
```

---

### Task 7: SPEC.md amendments, full suite, verification checklist

**Files:**
- Modify: `docs/SPEC.md`

**Interfaces:** none — documentation + verification.

- [ ] **Step 1: Amend the failover policy (SPEC.md ~line 75)**

In the paragraph beginning `` `FailoverAudioSource : AudioSource` composes ``, replace the sentence starting "Failover policy (`FailoverConfig` defaults): 3 s startup race" through "(flap damping)." with:

```
Failover policy (`FailoverConfig` defaults): mic-first — the phone mic starts immediately at Start (the tap is the only guaranteed-foreground moment; iOS forbids STARTING capture from the background), the wearable connects in parallel and capture upgrades to it on its first `.streaming` (immediately — nothing to distrust yet); 3 s reconnect grace (a disconnect within this window causes no source switch); 10 s return hysteresis before switching back to a wearable that already failed this session (flap damping — it never delays recovery from zero capture). A failed mic start is a recoverable **waiting** state (amber UI, session alive): the wearable's pending connect stays armed and the mic is retried on the next app foregrounding; a loud "Recording stopped" notification fires after 30 s in waiting, cancelled if capture recovers or the session stops (redesign: docs/superpowers/specs/2026-07-23-omi-failover-redesign-design.md).
```

- [ ] **Step 2: Amend the Settings section (SPEC.md ~line 506)**

In the `- **Omi Device** (M12):` bullet, after "…live only DURING an active listening session", insert:

```
 (idle shows "Connects when listening" plus a caption, never a bare "Not connected" — redesign 2026-07-23)
```

- [ ] **Step 3: Amend the notification note (SPEC.md, notifications/authorization context near line 375)**

After the numbered item about scheduling the fallback local notification, add a parenthetical note:

```
(Amendment 2026-07-23: notification authorization is requested as full [.alert, .sound], not provisional — the capture-unavailable alert must deliver loudly; see the failover-redesign spec.)
```

- [ ] **Step 4: Run the FULL test suite**

Run: `xcodebuild -project Sotto.xcodeproj -scheme Sotto -destination "$DEST" test 2>&1 | tail -12`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add docs/SPEC.md
git commit -m "docs: SPEC amendments for mic-first failover redesign"
```

- [ ] **Step 6: On-device verification (manual, with the user's iPhone + Omi)**

Report this checklist to the user — these need real hardware:

1. Start + immediate lock with the Omi OFF → a recording exists from t+0 (the reported bug's recipe, now unrepresentable).
2. Mid-session: session foreground, lock the phone, kill the Omi → amber Waiting on next look, loud notification at ~30 s, automatic mic recovery on unlock.
3. Cold start: Live Activity Start from the lock screen with the Omi off → Waiting, notification at 30 s, recovery via the notification tap specifically (unlocking alone must NOT be claimed as recovery).
4. Healthy-Omi start → mic runs briefly (orange indicator flicker), Omi takes over within ~2 s, first segment carries one source only.
5. Stop while waiting → NO notification fires afterward.
6. Settings: idle shows "Connects when listening" + caption; during a session with the Omi off it shows "Connecting…"; negotiation failures appear in Console (subsystem `app.decanlys.sotto`, categories `Failover`/`OmiTransport`).
```

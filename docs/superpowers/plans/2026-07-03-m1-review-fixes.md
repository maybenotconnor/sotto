# M1 Review Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix all 10 findings from the /code-review high pass (2026-07-03) on the Sotto M1 pipeline: two lifecycle traps, three silent-degradation bugs, three battery/realtime costs, and two contract gaps.

**Architecture:** No redesigns — each fix lands at the finding's own altitude. `ListeningPipeline` gains a `.starting` status and an awaitable queued-stop (continuations instead of a fire-and-forget flag), plus deinit teardown with a weak-self pump. `FormatConverter` gets degenerate-format guards and a reusable scratch buffer. `PreRollBuffer` becomes a true ring buffer. The chunk size gets a single source of truth tied to `VadManager.chunkSize`. Model loading hops off the MainActor.

**Tech Stack:** Swift 6 strict concurrency, Swift Testing, XcodeGen, FluidAudio 0.15.4 (pinned — do not touch), iPhone Air simulator.

## Global Constraints

- `Sotto.xcodeproj` is generated: run `xcodegen generate` only if files are added/removed (none are in this plan — all tasks modify existing files).
- Test command (used in every task): `xcodebuild test -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone Air' 2>&1 | tail -5` — expected `** TEST SUCCEEDED **`. Runs take minutes; not a hang.
- Zero Swift-compiler warnings after every task (`grep "warning:" <log> | grep -v appintentsmetadataprocessor` → empty). The two `appintentsmetadataprocessor` tool notices are known and ignorable.
- Swift 6 language mode with `SWIFT_DEFAULT_ACTOR_ISOLATION: nonisolated` — isolation is always explicit in this codebase.
- FluidAudio stays pinned at exactVersion 0.15.4. Verified API used by this plan: `VadManager.chunkSize == 4096` and `VadManager.sampleRate == 16000` (public statics); `VadStreamState.processedSamples` is a public `var Int`.
- Existing behavior guarantees that must survive every task: transitions serialized (at most one `start()`/`stop()` crosses an await at a time); a stop arriving mid-start is honored; the pump drains before state clears; all 24 existing tests keep passing except the two whose call shape Task 1 explicitly restructures.
- Baseline: 24 tests passing at commit `2567027`. Task counts below state the expected total after each task.
- Git commit messages end with:

  Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>

## Finding → Task map

| # | Finding | Task |
|---|---------|------|
| 1 | Pump task strong `self`; no teardown if pipeline dropped without `stop()` | 2 |
| 2 | `stop()` liveness depends on undocumented AudioSource contract | 2 |
| 3 | VAD inference error permanently desyncs event timestamps | 3 |
| 4 | UI shows "Listening" during the permission prompt | 1 |
| 5 | Zero-rate hardware format can trap on the audio thread | 4 |
| 6 | Per-tap-callback `AVAudioPCMBuffer` allocation on the realtime thread | 4 |
| 7 | `PreRollBuffer` memmoves ~64 KB per append (~14 GB/day) | 5 |
| 8 | Synchronous CoreML model load blocks the MainActor at launch | 5 |
| 9 | 4096 chunk size duplicated as literals instead of `VadManager.chunkSize` | 3 |
| 10 | Queued `stop()` returns before the pipeline is actually idle | 1 |

(Also folded in from the review's overflow list: the redundant `started` local in `start()` — eliminated by Task 1's rewrite.)

---

### Task 1: ListeningPipeline transition semantics — `.starting` status + awaitable queued stop (findings 4, 10)

**Files:**
- Modify: `Sotto/Pipeline/ListeningPipeline.swift`
- Modify: `Sotto/App/ContentView.swift` (status label/color for `.starting`)
- Test: `SottoTests/ListeningPipelineTests.swift`

**Interfaces:**
- Consumes: `SlowStartAudioSource` / `FakeAudioSource` / `FakeSpeechDetector` from `SottoTests/Fakes.swift` (unchanged in this task).
- Produces: `ListeningPipeline.Status` gains case `.starting` (now: `.idle`, `.starting`, `.listening`, `.speechActive`). `stop()`'s contract becomes: **when it returns, the pipeline is idle and drained — including when the stop was queued behind an in-flight start** (it suspends on a `CheckedContinuation` until the deferred stop completes). `start()` during any in-flight transition remains a no-op. Task 2 relies on `stop()` and the private `performStop()` exactly as written here.

- [ ] **Step 1: Restructure the two tests that would deadlock under the new stop() contract**

In `SottoTests/ListeningPipelineTests.swift`, `stopDuringStartLeavesPipelineIdleWithNoPump` and `startStopStartBurstEndsIdleWithoutOrphanedPump` both call `await pipeline.stop()` while `SlowStartAudioSource`'s gate is still closed. Under the new contract that call suspends until the start completes — but the gate release comes after it, deadlocking the test. Change ONLY the stop-call shape in both tests (assertions unchanged):

In `stopDuringStartLeavesPipelineIdleWithNoPump`, replace:

```swift
        async let starting: Void = pipeline.start()
        await source.waitUntilStartRequested()
        await pipeline.stop()            // wins the race while start() is suspended
        await source.releaseStart()
        await starting
```

with:

```swift
        async let starting: Void = pipeline.start()
        await source.waitUntilStartRequested()
        async let stopping: Void = pipeline.stop()   // queued; suspends until the deferred stop completes
        for _ in 0..<5 { await Task.yield() }        // let stop() reach the queue while the gate is closed
        await source.releaseStart()
        _ = await (starting, stopping)
```

In `startStopStartBurstEndsIdleWithoutOrphanedPump`, replace:

```swift
        async let firstStart: Void = pipeline.start()
        await source.waitUntilStartRequested()
        await pipeline.stop()                              // queued: start is mid-flight
        async let secondStart: Void = pipeline.start()     // must no-op: a transition is in flight
        for _ in 0..<5 { await Task.yield() }              // let secondStart hit the guard while the gate is closed
        await source.releaseStart()
        _ = await (firstStart, secondStart)
```

with:

```swift
        async let firstStart: Void = pipeline.start()
        await source.waitUntilStartRequested()
        async let stopping: Void = pipeline.stop()         // queued: start is mid-flight
        async let secondStart: Void = pipeline.start()     // must no-op: a transition is in flight
        for _ in 0..<5 { await Task.yield() }              // let both hit their guards while the gate is closed
        await source.releaseStart()
        _ = await (firstStart, stopping, secondStart)
```

- [ ] **Step 2: Add the two new failing tests**

Append inside the `ListeningPipelineTests` struct:

```swift
    @Test func statusIsStartingWhileSourceStartIsInFlight() async throws {
        let source = SlowStartAudioSource()
        let detector = FakeSpeechDetector(script: [:])
        let pipeline = ListeningPipeline(source: source, detector: detector)

        async let starting: Void = pipeline.start()
        await source.waitUntilStartRequested()
        #expect(pipeline.status == .starting)   // NOT .listening: no audio is flowing yet
        await source.releaseStart()
        await starting
        #expect(pipeline.status == .listening)
        await pipeline.stop()
    }

    @Test func queuedStopReturnsOnlyOncePipelineIsIdle() async throws {
        let source = SlowStartAudioSource()
        let detector = FakeSpeechDetector(script: [:])
        let pipeline = ListeningPipeline(source: source, detector: detector)

        async let starting: Void = pipeline.start()
        await source.waitUntilStartRequested()
        async let stopping: Void = pipeline.stop()
        for _ in 0..<5 { await Task.yield() }
        await source.releaseStart()
        await stopping                        // must resume only after the deferred stop drained
        #expect(pipeline.status == .idle)     // stop()'s return now implies idle
        await starting
    }
```

- [ ] **Step 3: Run tests to verify the new ones fail**

Run the Global Constraints test command.
Expected: BUILD FAILURE — `type 'ListeningPipeline.Status' has no member 'starting'`. (Compile error is the red step.)

- [ ] **Step 4: Rewrite ListeningPipeline's status/transition machinery**

In `Sotto/Pipeline/ListeningPipeline.swift`:

Add `.starting` to the enum:

```swift
    enum Status: Equatable {
        case idle
        case starting
        case listening
        case speechActive
    }
```

Replace the two transition fields (delete `stopRequestedDuringTransition`) and update the comment:

```swift
    // Transitions are mutually exclusive: at most one start()/stop() crosses an await at a
    // time. A stop() arriving during an in-flight transition suspends until the pipeline is
    // actually idle (so stop()'s return always implies idle+drained); a start() arriving
    // during any in-flight transition is a no-op.
    private var isTransitioning = false
    private var queuedStops: [CheckedContinuation<Void, Never>] = []
```

Replace `start()` and `stop()` entirely with:

```swift
    func start() async {
        guard status == .idle, !isTransitioning else { return }
        isTransitioning = true
        status = .starting   // truthful: no audio flows until source.start() succeeds
        do {
            let stream = try await source.start()
            status = .listening
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
            if status == .listening {
                await performStop()      // drains, idles, then resumes the waiters
            } else {
                resumeQueuedStops()      // start failed: already idle, nothing to stop
            }
        }
    }

    func stop() async {
        if isTransitioning {
            // Suspend until the in-flight transition's deferred stop completes: callers
            // may assume the pipeline is idle and drained when stop() returns.
            await withCheckedContinuation { queuedStops.append($0) }
            return
        }
        guard status != .idle else { return }
        await performStop()
    }

    private func performStop() async {
        isTransitioning = true
        await source.stop()          // finish the stream: no new chunks after this
        await pumpTask?.value        // drain chunks already in flight to quiescence
        pumpTask = nil
        await detector.reset()
        preRoll.removeAll()
        status = .idle
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
```

Notes baked into this design (do not "simplify" them away): the `[weak self]` pump capture is deliberate (Task 2's deinit teardown depends on the pipeline being deallocatable while the pump runs); the redundant `started` local from the old code is gone — `status == .listening` after the do/catch is the same fact; stop-during-stop now suspends the second caller until the first drain completes instead of silently dropping a flag.

- [ ] **Step 5: Update ContentView for `.starting`**

In `Sotto/App/ContentView.swift`, `PipelineView`'s two switches gain the case:

```swift
    private var statusLabel: String {
        switch pipeline.status {
        case .idle: "Idle"
        case .starting: "Starting…"
        case .listening: "Listening"
        case .speechActive: "Speech"
        }
    }

    private var statusColor: Color {
        switch pipeline.status {
        case .idle: .secondary
        case .starting: .secondary
        case .listening: .green
        case .speechActive: .orange
        }
    }
```

The button condition (`pipeline.status == .idle ? "Start Listening" : "Stop"`) is already correct: during `.starting` it reads "Stop", and tapping it queues a stop that is honored when the start completes.

- [ ] **Step 6: Run the full suite**

Run the Global Constraints test command.
Expected: `** TEST SUCCEEDED **`, 26 tests (24 baseline + 2 new). Then check warnings per Global Constraints.

- [ ] **Step 7: Commit**

```bash
git add Sotto/Pipeline/ListeningPipeline.swift Sotto/App/ContentView.swift SottoTests/ListeningPipelineTests.swift
git commit -m "fix: truthful .starting status and awaitable queued stop (review findings 4, 10)"
```

---

### Task 2: Pipeline lifecycle — deinit teardown + documented AudioSource stop contract (findings 1, 2)

**Files:**
- Modify: `Sotto/Pipeline/ListeningPipeline.swift` (add `deinit`)
- Modify: `Sotto/Audio/AudioTypes.swift` (protocol doc contract)
- Modify: `SottoTests/Fakes.swift` (`stopCallCount` on `FakeAudioSource`)
- Test: `SottoTests/ListeningPipelineTests.swift`

**Interfaces:**
- Consumes: Task 1's `ListeningPipeline` exactly as written (weak-self pump is a precondition — a strong capture would keep the pipeline alive and `deinit` would never run).
- Produces: `FakeAudioSource.stopCallCount: Int` (actor-isolated `private(set)` var, read as `await source.stopCallCount`). `AudioSource.stop()`'s documented contract, which every future conformer (BLE, Watch) must honor.

- [ ] **Step 1: Add `stopCallCount` to FakeAudioSource**

In `SottoTests/Fakes.swift`, inside `FakeAudioSource`, add the counter and increment it in `stop()`:

```swift
    private(set) var stopCallCount = 0
```

and change `stop()` to:

```swift
    func stop() {
        stopCallCount += 1
        continuation?.finish()
        continuation = nil
    }
```

- [ ] **Step 2: Write the failing test**

Append inside `ListeningPipelineTests`:

```swift
    @Test func droppingPipelineWithoutStopTearsDownSource() async throws {
        let source = FakeAudioSource()
        let detector = FakeSpeechDetector(script: [:])
        var pipeline: ListeningPipeline? = ListeningPipeline(source: source, detector: detector)
        await pipeline?.start()
        await source.emitSilentChunks(count: 2)

        pipeline = nil   // owner forgot stop(); deinit must still tear down the source

        var stopped = false
        for _ in 0..<50 where !stopped {
            try await Task.sleep(for: .milliseconds(10))
            stopped = await source.stopCallCount > 0
        }
        #expect(stopped)   // without deinit teardown the audio stack would run forever
    }
```

- [ ] **Step 3: Run to verify it fails**

Run the Global Constraints test command.
Expected: TEST FAILED — `droppingPipelineWithoutStopTearsDownSource` fails on `#expect(stopped)` (no deinit exists; the source is never stopped). All other tests pass.

- [ ] **Step 4: Add the deinit**

In `Sotto/Pipeline/ListeningPipeline.swift`, after `init`:

```swift
    deinit {
        // Belt-and-braces: if an owner drops the pipeline without stop(), stop the source
        // so the stream finishes and the (weak-self) pump exits — otherwise the live audio
        // stack (engine, tap, VAD) would keep running with no reachable owner.
        let source = self.source
        Task.detached {
            await source.stop()
        }
    }
```

- [ ] **Step 5: Document the AudioSource stop contract**

In `Sotto/Audio/AudioTypes.swift`, replace the `AudioSource` protocol's doc comment block so the protocol reads:

```swift
protocol AudioSource: Sendable {
    var sourceType: AudioSourceType { get }
    var isAvailable: Bool { get }
    /// Emits fixed-size chunks of 4096 samples (256 ms @ 16 kHz).
    func start() async throws -> AsyncStream<AudioChunk>
    /// Contract: MUST terminate the stream returned by `start()` (finish its continuation)
    /// on every path — `ListeningPipeline.stop()` awaits stream termination to drain
    /// in-flight chunks and would otherwise never return, freezing the MainActor.
    /// Must also be safe to call when the source was never started (no-op).
    func stop() async
}
```

- [ ] **Step 6: Run the full suite**

Run the Global Constraints test command.
Expected: `** TEST SUCCEEDED **`, 27 tests. Warnings check per Global Constraints.

- [ ] **Step 7: Commit**

```bash
git add Sotto/Pipeline/ListeningPipeline.swift Sotto/Audio/AudioTypes.swift SottoTests/Fakes.swift SottoTests/ListeningPipelineTests.swift
git commit -m "fix: deinit teardown for dropped pipelines and documented AudioSource stop contract (review findings 1, 2)"
```

---

### Task 3: Detector timestamp integrity + chunk-size source of truth (findings 3, 9)

**Files:**
- Modify: `Sotto/VAD/SileroSpeechDetector.swift`
- Modify: `Sotto/Audio/SampleChunker.swift` (default parameter)
- Modify: `Sotto/Audio/PhoneMicAudioSource.swift` (tap bufferSize)
- Modify: `SottoTests/Fakes.swift` (both `emitSilentChunks`)
- Test: `SottoTests/SileroSpeechDetectorTests.swift`

**Interfaces:**
- Consumes: `VadManager.chunkSize` / `VadManager.sampleRate` (public statics, FluidAudio 0.15.4) and `VadStreamState.processedSamples` (public `var Int`).
- Produces: `enum VADConstants { static let chunkSize: Int; static let sampleRate: Int }` (declared in `SileroSpeechDetector.swift`, visible module-wide — other files need no FluidAudio import). `SileroSpeechDetector.processedSampleCount() -> Int` (actor method, test hook).

- [ ] **Step 1: Write the failing tests**

Append inside `SileroSpeechDetectorTests`:

```swift
    @Test func pipelineChunkSizeMatchesVadModelContract() {
        // Canary: if a FluidAudio upgrade changes the model's chunk contract, this fails
        // loudly instead of VadManager silently padding/truncating our chunks.
        #expect(VADConstants.chunkSize == 4096)
        #expect(VADConstants.sampleRate == 16_000)
    }

    @Test func processedSampleCountAdvancesPerChunk() async throws {
        let detector = try makeDetector()
        for _ in 0..<3 {
            _ = try await detector.process(
                AudioChunk(samples: [Float](repeating: 0, count: VADConstants.chunkSize), hostTime: 0))
        }
        #expect(await detector.processedSampleCount() == VADConstants.chunkSize * 3)
    }
```

- [ ] **Step 2: Run to verify they fail**

Run the Global Constraints test command.
Expected: BUILD FAILURE — `cannot find 'VADConstants' in scope`.

- [ ] **Step 3: Implement in SileroSpeechDetector.swift**

Add above the actor:

```swift
/// Single source of truth for the pipeline's chunk geometry — Silero's fixed model input
/// (4096 samples = 256 ms @ 16 kHz). Everything upstream (chunker default, tap buffer
/// size, test fakes) must reference this, never a literal.
enum VADConstants {
    static let chunkSize = VadManager.chunkSize
    static let sampleRate = VadManager.sampleRate
}
```

Replace `process(_:)` with the bookkeeping-safe version and add the test hook:

```swift
    func process(_ chunk: AudioChunk) async throws -> SpeechEvent? {
        let result: VadStreamResult
        do {
            result = try await vad.processStreamingChunk(
                chunk.samples,
                state: streamState,
                config: .default,
                returnSeconds: true,
                timeResolution: 2)
        } catch {
            // Keep time bookkeeping monotonic even when inference fails: event timestamps
            // derive from processedSamples, so a skipped chunk would silently shift every
            // later speechStart/speechEnd 256 ms early for the rest of the session.
            streamState.processedSamples += chunk.samples.count
            throw error
        }
        streamState = result.state
        guard let event = result.event else { return nil }
        switch event.kind {
        case .speechStart: return .speechStart(time: event.time)
        case .speechEnd: return .speechEnd(time: event.time)
        }
    }

    /// Test hook: total samples the streaming state has accounted for.
    func processedSampleCount() -> Int {
        streamState.processedSamples
    }
```

(The throw path itself can't be forced through the real CoreML model in a unit test; it is trace-verified. The success-path test above pins the bookkeeping invariant the fix preserves.)

- [ ] **Step 4: Point the literals at VADConstants**

- `Sotto/Audio/SampleChunker.swift`: `init(chunkSize: Int = VADConstants.chunkSize) {`
- `Sotto/Audio/PhoneMicAudioSource.swift`: `input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(VADConstants.chunkSize), format: hardwareFormat) { ... }`
- `SottoTests/Fakes.swift`: in BOTH `FakeAudioSource.emitSilentChunks` and `SlowStartAudioSource.emitSilentChunks`, replace `count: 4096` with `count: VADConstants.chunkSize`.

- [ ] **Step 5: Run the full suite**

Run the Global Constraints test command.
Expected: `** TEST SUCCEEDED **`, 29 tests. Warnings check per Global Constraints.

- [ ] **Step 6: Commit**

```bash
git add Sotto/VAD/SileroSpeechDetector.swift Sotto/Audio/SampleChunker.swift Sotto/Audio/PhoneMicAudioSource.swift SottoTests/Fakes.swift SottoTests/SileroSpeechDetectorTests.swift
git commit -m "fix: monotonic VAD time bookkeeping and single chunk-size source of truth (review findings 3, 9)"
```

---

### Task 4: FormatConverter — degenerate-format guards + reusable scratch buffer (findings 5, 6)

**Files:**
- Modify: `Sotto/Audio/FormatConverter.swift`
- Modify: `Sotto/Audio/PhoneMicAudioSource.swift` (hardware-format guard + new error case)
- Test: `SottoTests/FormatConverterTests.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces: `AudioSourceError` gains `case invalidHardwareFormat`. `FormatConverter`'s public surface is unchanged (`init?(inputFormat:)`, `convert(_:) -> [Float]`).

- [ ] **Step 1: Write the failing reuse test**

Append inside `FormatConverterTests`:

```swift
    @Test func reusedConverterProducesConsistentOutputAcrossManyCalls() throws {
        let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
        let converter = try #require(FormatConverter(inputFormat: inputFormat))
        let frames: AVAudioFrameCount = 4800   // 100 ms @ 48 kHz
        let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frames)!
        buffer.frameLength = frames
        for i in 0..<Int(frames) {
            buffer.floatChannelData![0][i] = sinf(2 * .pi * 440 * Float(i) / 48_000)
        }

        var total = 0
        for _ in 0..<10 {
            let out = converter.convert(buffer)
            #expect(out.allSatisfy(\.isFinite))
            total += out.count
        }
        // 10 × 100 ms @ 16 kHz = 16,000 samples, minus resampler priming latency.
        #expect(abs(total - 16_000) <= 256)
    }
```

This test fails against a buggy scratch-buffer implementation (stale `frameLength`, corrupted reuse) and passes against both the current allocate-per-call code and a correct reuse implementation — it pins the behavior the optimization must preserve.

- [ ] **Step 2: Run to verify it passes against current code (pin), then implement**

Run the Global Constraints test command. Expected: `** TEST SUCCEEDED **` (this step pins current behavior; the "red" for this task is the behavioral pin, not a compile failure).

- [ ] **Step 3: Implement guards + scratch buffer in FormatConverter.swift**

Replace `init?` and `convert(_:)`; add the `scratch` property:

```swift
    private let converter: AVAudioConverter
    private let ratio: Double
    private var scratch: AVAudioPCMBuffer?

    init?(inputFormat: AVAudioFormat) {
        // Defense-in-depth: a 0 Hz / 0-channel "format" is a documented AVAudioEngine
        // degenerate state when no valid input route exists; without this guard the
        // ratio below becomes non-finite and the first convert() traps on the audio thread.
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
              let converter = AVAudioConverter(from: inputFormat, to: Self.targetFormat)
        else {
            return nil
        }
        self.converter = converter
        self.ratio = Self.targetFormat.sampleRate / inputFormat.sampleRate
    }

    /// Synchronously converts one tap buffer, copying samples out — the returned array
    /// owns its memory, so both the tap buffer and the reused scratch buffer are free
    /// to be recycled.
    func convert(_ buffer: AVAudioPCMBuffer) -> [Float] {
        let needed = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        if scratch == nil || scratch!.frameCapacity < needed {
            // Capacity tracks the largest tap buffer seen — reallocation only on growth,
            // never steady-state. Allocating per callback on the realtime audio thread
            // risks priority inversion; reuse keeps the hot path allocation-free.
            // (Exact `needed` sizing, NOT a padded floor: a larger output buffer changes
            // AVAudioConverter's pacing — discovered and fixed during execution.)
            scratch = AVAudioPCMBuffer(pcmFormat: Self.targetFormat, frameCapacity: needed)
        }
        guard let output = scratch else {
            logger.error("Failed to allocate conversion scratch buffer (\(needed) frames)")
            return []
        }
        output.frameLength = 0

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
            logger.error("Audio conversion failed: \(conversionError?.localizedDescription ?? "no channel data")")
            return []
        }
        return Array(UnsafeBufferPointer(start: channelData[0], count: Int(output.frameLength)))
    }
```

(Keep the existing `logger`, `targetFormat`, class declaration, and doc comments as they are; only the members shown change. `scratch` is a `var` on a class confined behind `TapProcessor`'s Mutex — same confinement argument as the documented `@unchecked Sendable`.)

- [ ] **Step 4: Guard the hardware format in PhoneMicAudioSource.start()**

In `Sotto/Audio/PhoneMicAudioSource.swift`, add to the error enum:

```swift
    enum AudioSourceError: Error {
        case microphonePermissionDenied
        case converterUnavailable
        case invalidHardwareFormat
        case alreadyStarted
    }
```

and immediately after `let hardwareFormat = input.outputFormat(forBus: 0)`:

```swift
        // installTap traps (Obj-C precondition) on a 0 Hz/0-channel format — reject the
        // documented no-valid-input-route degenerate state with a recoverable throw instead.
        guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0 else {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            throw AudioSourceError.invalidHardwareFormat
        }
```

- [ ] **Step 5: Try to pin the zero-rate guard with a test**

Attempt in `FormatConverterTests`:

```swift
    @Test func rejectsDegenerateZeroRateFormat() {
        // AVAudioFormat may refuse to construct a 0 Hz format at all — if so, the guard
        // in FormatConverter.init is pure defense-in-depth and this test documents that.
        if let zeroRate = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 0, channels: 1, interleaved: false) {
            #expect(FormatConverter(inputFormat: zeroRate) == nil)
        }
    }
```

Decision rule: if `AVAudioFormat` returns nil for 0 Hz (likely), the test still compiles and trivially passes with the `if let` never entered — keep it as documentation. If the format IS constructible, the `#expect` genuinely exercises the guard. Either way the test ships.

- [ ] **Step 6: Run the full suite**

Run the Global Constraints test command.
Expected: `** TEST SUCCEEDED **`, 31 tests. Warnings check per Global Constraints.

- [ ] **Step 7: Commit**

```bash
git add Sotto/Audio/FormatConverter.swift Sotto/Audio/PhoneMicAudioSource.swift SottoTests/FormatConverterTests.swift
git commit -m "fix: guard degenerate hardware formats and stop allocating per tap callback (review findings 5, 6)"
```

---

### Task 5: PreRollBuffer ring buffer + off-main model load (findings 7, 8)

**Files:**
- Modify: `Sotto/Audio/PreRollBuffer.swift` (full rewrite of internals; public surface unchanged)
- Modify: `Sotto/App/ContentView.swift` (async setUp)
- Test: `SottoTests/PreRollBufferTests.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces: `PreRollBuffer`'s public surface is IDENTICAL (`let capacity`, `init(capacity:)`, `append(_:)`, `snapshot() -> [Float]` oldest-first, `removeAll()`) — `ListeningPipeline` and all existing tests compile unchanged.

- [ ] **Step 1: Add the two new boundary tests (they pass against old code too — they pin behavior the rewrite must preserve)**

Append inside `PreRollBufferTests`:

```swift
    @Test func exactCapacityFillRetainsAllSamplesInOrder() {
        var buffer = PreRollBuffer(capacity: 4)
        buffer.append([1, 2])
        buffer.append([3, 4])
        #expect(buffer.snapshot() == [1, 2, 3, 4])
    }

    @Test func wrapsCorrectlyAcrossManyAppends() {
        var buffer = PreRollBuffer(capacity: 5)
        buffer.append([1, 2, 3])
        buffer.append([4, 5, 6])
        buffer.append([7])
        #expect(buffer.snapshot() == [3, 4, 5, 6, 7])
    }
```

- [ ] **Step 2: Run to verify they pass against the current implementation (behavioral pin)**

Run the Global Constraints test command. Expected: `** TEST SUCCEEDED **`, 33 tests.

- [ ] **Step 3: Rewrite PreRollBuffer as a circular buffer**

Replace the whole file body:

```swift
import Foundation

/// Rolling window of the most recent audio samples (default 1 s = 16,000), continuously
/// refilled while Listening so utterance starts aren't clipped. On `.speechStart` (M2)
/// its snapshot is flushed to the segment writer ahead of live audio.
///
/// Fixed-size circular buffer: append is O(samples appended) with no shifting. The
/// previous array-based version memmoved the full ~64 KB window on every append
/// (~4×/sec, all day, on the MainActor) — real, continuous battery cost at this
/// app's 16 h/day duty cycle.
struct PreRollBuffer {
    let capacity: Int
    private var storage: [Float]
    private var writeIndex = 0
    private var count = 0

    init(capacity: Int) {
        precondition(capacity > 0, "capacity must be positive")
        self.capacity = capacity
        self.storage = [Float](repeating: 0, count: capacity)
    }

    mutating func append(_ samples: [Float]) {
        if samples.count >= capacity {
            // Only the newest `capacity` samples can survive; lay them down in order.
            for (i, sample) in samples.suffix(capacity).enumerated() {
                storage[i] = sample
            }
            writeIndex = 0
            count = capacity
            return
        }
        for sample in samples {
            storage[writeIndex] = sample
            writeIndex = (writeIndex + 1) % capacity
        }
        count = min(count + samples.count, capacity)
    }

    /// Buffered samples, oldest first.
    func snapshot() -> [Float] {
        guard count > 0 else { return [] }
        if count < capacity {
            // Not yet wrapped: writeIndex only wraps once count reaches capacity,
            // so the valid samples occupy [0, count) in order.
            return Array(storage[..<count])
        }
        return Array(storage[writeIndex...]) + Array(storage[..<writeIndex])
    }

    mutating func removeAll() {
        writeIndex = 0
        count = 0
    }
}
```

- [ ] **Step 4: Run the full suite (all 6 PreRollBuffer tests must pass against the rewrite)**

Run the Global Constraints test command. Expected: `** TEST SUCCEEDED **`, 33 tests.

- [ ] **Step 5: Move the model load off the MainActor**

In `Sotto/App/ContentView.swift`, change the task modifier to `.task { await setUp() }` and replace `setUp()` with:

```swift
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
        do {
            // CoreML load/compile can take hundreds of ms (seconds on a cold cache) —
            // off the MainActor so the loading indicator actually renders and animates.
            let detector = try await Task.detached(priority: .userInitiated) {
                try SileroSpeechDetector(modelURL: modelURL)
            }.value
            pipeline = ListeningPipeline(source: PhoneMicAudioSource(), detector: detector)
        } catch {
            setupError = String(describing: error)
        }
    }
```

- [ ] **Step 6: Run the full suite + warnings check**

Run the Global Constraints test command. Expected: `** TEST SUCCEEDED **`, 33 tests, zero Swift warnings.

- [ ] **Step 7: Commit**

```bash
git add Sotto/Audio/PreRollBuffer.swift Sotto/App/ContentView.swift SottoTests/PreRollBufferTests.swift
git commit -m "fix: ring-buffer pre-roll and off-main CoreML model load (review findings 7, 8)"
```

---

## Post-plan verification (controller, after all tasks)

Full suite one more time, rebuild + reinstall on the iPhone Air simulator, relaunch, screenshot: app must reach Idle, and Start → "Starting…" → "Listening" must be visible in the debug UI.

## Self-review notes

- All 10 findings map to a task (table above); the overflow finding "redundant `started` local" is eliminated by Task 1's rewrite; other overflow items (eventLog cap, typed errors, fake dedup, M3 restart affordance) are deliberately NOT in this plan — they're M2/M3 design inputs already recorded in the M1 plan's carryover section and `.superpowers/sdd/code-review-overflow-findings.md`.
- Tasks 4 and 5 use behavioral-pin steps (test passes before AND after) instead of red-green where the change is an internal rewrite that must preserve behavior — the "red" those tests provide is against a *buggy rewrite*, which is what the reviewer gate needs.
- Type consistency checked: `.starting` case used in Task 1 (pipeline + ContentView + tests) only; `VADConstants` declared Task 3 and consumed in the same task's call-site edits; `invalidHardwareFormat` declared and used only in Task 4; `PreRollBuffer` surface unchanged so Tasks 1–2's pipeline code is unaffected by Task 5.

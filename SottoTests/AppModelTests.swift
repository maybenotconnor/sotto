import Foundation
import Testing
@testable import Sotto

@MainActor
struct AppModelTests {
    @Test func intentHandlerIsRegisteredAtConstruction() async throws {
        // IntentHandlers.shared is process-global state (Fix 4: ownership-aware
        // registration). `model` MUST stay alive across the assertion — once it
        // deallocates, its weak `owner` slot is reclaimed and a later AppModel() in a
        // different test could then win registration instead, but here `_ = model`
        // keeps it retained for the whole test body, so this instance is guaranteed
        // to be the registered owner.
        let model = AppModel()
        _ = model
        #expect(IntentHandlers.shared.toggle != nil)   // cold background launch can toggle
    }

    @Test func downloadSpeechModelTransitionsThroughStates() async throws {
        let installer = FakeAssetInstaller(installed: false)
        let model = AppModel(assetInstaller: installer)
        await model.ensureSetUp()
        #expect(model.assetState == .notInstalled)

        await model.downloadSpeechModel()

        #expect(model.assetState == .installed)
        #expect(await installer.installCalls == 1)
    }

    @Test func downloadFailureLandsInFailedAndAllowsRetry() async throws {
        struct Boom: Error {}
        let installer = FakeAssetInstaller(installed: false)
        await installer.setError(Boom())
        let model = AppModel(assetInstaller: installer)
        await model.ensureSetUp()
        await model.downloadSpeechModel()
        if case .failed = model.assetState {} else { Issue.record("expected .failed") }

        await installer.setError(nil)
        await model.downloadSpeechModel()
        #expect(model.assetState == .installed)
    }

    /// M6b follow-up: Simulator / non-Apple-Intelligence hardware must land in the truthful
    /// `.unsupported` state (no download button, no network-failure copy) rather than
    /// `.notInstalled` — and `downloadSpeechModel()` must stay a no-op there since no download
    /// could ever succeed.
    @Test func unsupportedDeviceSkipsDownloadAndStaysNoOp() async throws {
        let installer = FakeAssetInstaller(installed: false)
        await installer.setSupported(false)
        let model = AppModel(assetInstaller: installer)

        await model.ensureSetUp()
        #expect(model.assetState == .unsupported)

        await model.downloadSpeechModel()
        #expect(model.assetState == .unsupported)
        #expect(await installer.installCalls == 0)
    }

    @Test func historyPagesSevenContentDaysNewestFirst() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HistTests-\(UUID().uuidString)")
        // 10 content days + 1 empty day folder:
        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.calendar = Calendar(identifier: .gregorian)
        dayFormatter.dateFormat = "yyyy-MM-dd"
        let store = DayIndexStore(rootDirectory: root)
        for offset in 0..<10 {
            let day = Calendar.current.date(byAdding: .day, value: -offset, to: Date())!
            let dir = root.appendingPathComponent(dayFormatter.string(from: day), isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            await store.recordQueuedSegment(
                m4aURL: dir.appendingPathComponent("10-00-00.m4a"), startTime: day, duration: 60)
        }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("2001-01-01"), withIntermediateDirectories: true)

        let model = AppModel(
            assetInstaller: FakeAssetInstaller(installed: true), segmentRootOverride: root)
        await model.ensureSetUp()
        await model.loadInitialHistory()

        #expect(model.historySections.count == 7)
        #expect(model.hasMoreHistory)
        #expect(model.historySections.first!.id > model.historySections.last!.id)  // newest first

        await model.loadMoreHistory()
        #expect(model.historySections.count == 10)      // empty 2001 folder contributes nothing
        #expect(!model.hasMoreHistory)
    }

    /// M9 review Important #2: deleting a day's only segment must drop that day's section
    /// entirely on the resulting `refreshLoadedHistory()` — otherwise its now-content-less
    /// sticky header keeps showing until the next full reload.
    @Test func deletingDaysLastSegmentDropsEmptySection() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeleteTests-\(UUID().uuidString)")
        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.calendar = Calendar(identifier: .gregorian)
        dayFormatter.dateFormat = "yyyy-MM-dd"
        // Yesterday (not "today") so this test exercises only the content-filter fix, not
        // refreshLoadedHistory's separate "prepend today" logic.
        let day = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        let dir = root.appendingPathComponent(dayFormatter.string(from: day), isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let m4aURL = dir.appendingPathComponent("09-15-30.m4a")
        let mdURL = dir.appendingPathComponent("09-15-30.md")
        try Data([0x01]).write(to: m4aURL)
        try "placeholder".write(to: mdURL, atomically: true, encoding: .utf8)

        let indexStore = DayIndexStore(rootDirectory: root)
        await indexStore.recordQueuedSegment(m4aURL: m4aURL, startTime: day, duration: 12)

        let model = AppModel(
            assetInstaller: FakeAssetInstaller(installed: true), segmentRootOverride: root)
        await model.ensureSetUp()
        await model.loadInitialHistory()
        #expect(model.historySections.count == 1)

        await model.deleteSegment(m4aURL: m4aURL)   // removes the day's only segment

        #expect(model.historySections.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: m4aURL.path))
    }

    private func section(day: String, entries: [(id: String, state: String)]) -> AppModel.HistorySection {
        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.calendar = Calendar(identifier: .gregorian)
        dayFormatter.dateFormat = "yyyy-MM-dd"
        let dir = URL(fileURLWithPath: "/tmp/EligibilityTests/\(day)")
        let segments = entries.enumerated().map { offset, entry in
            DaySegmentEntry(
                id: entry.id,
                startTime: dayFormatter.date(from: day)!.addingTimeInterval(Double(offset) * 60),
                duration: 10, backend: "speechAnalyzer", hasAudio: false, wordCount: 3,
                transcriptionState: entry.state)
        }
        return AppModel.HistorySection(
            id: day, date: dayFormatter.date(from: day)!, dayDirectory: dir,
            index: DayIndex(date: day, segments: segments, gaps: []))
    }

    @Test func mergeEligibilityGatesSelections() {
        let sections = [
            section(day: "2026-03-15", entries: [("08-00-00", "done")]),
            section(day: "2026-03-14", entries: [
                ("09-15-30", "done"), ("10-01-00", "done"), ("11-00-00", "queued"),
            ]),
        ]

        #expect(AppModel.mergeEligibility(
            selectedKeys: ["2026-03-14/09-15-30"], sections: sections) == .tooFew)
        #expect(AppModel.mergeEligibility(
            selectedKeys: ["2026-03-14/09-15-30", "2026-03-15/08-00-00"],
            sections: sections) == .multipleDays)
        #expect(AppModel.mergeEligibility(
            selectedKeys: ["2026-03-14/09-15-30", "2026-03-14/11-00-00"],
            sections: sections) == .notAllDone)

        let eligibility = AppModel.mergeEligibility(
            selectedKeys: ["2026-03-14/10-01-00", "2026-03-14/09-15-30"],
            sections: sections)
        guard case .eligible(let dayDirectory, let entries) = eligibility else {
            Issue.record("expected .eligible, got \(eligibility)")
            return
        }
        #expect(dayDirectory.lastPathComponent == "2026-03-14")
        #expect(entries.map(\.id) == ["09-15-30", "10-01-00"])   // sorted chronologically
    }

    @Test func mergeEligibilityIgnoresStaleKeys() {
        let sections = [section(day: "2026-03-14", entries: [("09-15-30", "done")])]
        #expect(AppModel.mergeEligibility(
            selectedKeys: ["2026-03-14/09-15-30", "2026-03-14/99-99-99"],
            sections: sections) == .tooFew)
    }

    @Test func bluetoothBannerReasonOnlyForPairedActionableUnavailability() {
        // Unpaired: never shown, regardless of connection state.
        #expect(AppModel.bluetoothBannerReason(
            pairedOmiName: nil, connectionState: .unavailable(.poweredOff)) == nil)

        // Paired but connected/streaming/disconnected/nil: nothing actionable to surface.
        #expect(AppModel.bluetoothBannerReason(pairedOmiName: "Omi", connectionState: nil) == nil)
        #expect(AppModel.bluetoothBannerReason(
            pairedOmiName: "Omi", connectionState: .connected) == nil)
        #expect(AppModel.bluetoothBannerReason(
            pairedOmiName: "Omi", connectionState: .disconnected) == nil)

        // Paired + unsupported: excluded — no Settings toggle can fix it, so it isn't an
        // actionable banner (Settings' status text still surfaces it separately).
        #expect(AppModel.bluetoothBannerReason(
            pairedOmiName: "Omi", connectionState: .unavailable(.unsupported)) == nil)

        // Paired + poweredOff/unauthorized: the two actionable reasons the banner covers.
        #expect(AppModel.bluetoothBannerReason(
            pairedOmiName: "Omi", connectionState: .unavailable(.poweredOff)) == .poweredOff)
        #expect(AppModel.bluetoothBannerReason(
            pairedOmiName: "Omi", connectionState: .unavailable(.unauthorized)) == .unauthorized)
    }

    @Test func mergeSegmentsCombinesFilesIndexAndHistory() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MergeModelTests-\(UUID().uuidString)")
        // Yesterday, so refreshLoadedHistory's "prepend today" logic stays out of the way.
        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.calendar = Calendar(identifier: .gregorian)
        dayFormatter.dateFormat = "yyyy-MM-dd"
        let day = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        let dayName = dayFormatter.string(from: day)
        let dir = root.appendingPathComponent(dayName, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Frontmatter dates are fixed 2026-03-14 strings; folder day differs — fine, the
        // model reads entries from the index, and the merger only compares parts to each
        // other. (Production merges always have matching folder/frontmatter days.)
        try ConversationMergerTests.partOne.write(
            to: dir.appendingPathComponent("09-15-30.md"), atomically: true, encoding: .utf8)
        try ConversationMergerTests.partTwo.write(
            to: dir.appendingPathComponent("10-01-00.md"), atomically: true, encoding: .utf8)

        let model = AppModel(
            assetInstaller: FakeAssetInstaller(installed: true), segmentRootOverride: root)
        await model.ensureSetUp()
        await model.loadInitialHistory()   // no _day.json → rebuilds; both entries "done"
        let section = model.historySections[0]
        #expect(section.index.segments.count == 2)

        let ok = await model.mergeSegments(
            dayDirectory: section.dayDirectory, entries: section.index.segments)

        #expect(ok)
        #expect(model.historySections[0].index.segments.count == 1)
        #expect(model.historySections[0].index.segments[0].id == "09-15-30")
        #expect(!FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("10-01-00.md").path))
        let merged = try String(
            contentsOf: dir.appendingPathComponent("09-15-30.md"), encoding: .utf8)
        #expect(merged.contains("Second part text four five."))
    }

    @Test func renameSegmentRewritesFileIndexAndHistory() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RenameModelTests-\(UUID().uuidString)")
        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.calendar = Calendar(identifier: .gregorian)
        dayFormatter.dateFormat = "yyyy-MM-dd"
        let day = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        let dir = root.appendingPathComponent(dayFormatter.string(from: day), isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try ConversationMergerTests.partOne.write(
            to: dir.appendingPathComponent("09-15-30.md"), atomically: true, encoding: .utf8)

        let model = AppModel(
            assetInstaller: FakeAssetInstaller(installed: true), segmentRootOverride: root)
        await model.ensureSetUp()
        await model.loadInitialHistory()   // no _day.json → rebuilds; entry is "done"
        let entry = model.historySections[0].index.segments[0]
        #expect(entry.title == nil)

        await model.renameSegment(
            m4aURL: dir.appendingPathComponent("09-15-30.m4a"),
            title: "Morning standup", startTime: entry.startTime)

        // File is the source of truth…
        let file = try #require(TranscriptFile.parse(
            url: dir.appendingPathComponent("09-15-30.md")))
        #expect(file.title == "Morning standup")
        #expect(file.transcriptBody.contains("First part text one two three."))
        // …index followed…
        let indexed = await model.loadDayIndex(for: day)?.segments.first
        #expect(indexed?.title == "Morning standup")
        // …and the loaded history refreshed in place.
        #expect(model.historySections[0].index.segments[0].title == "Morning standup")
    }

    @Test func renameSegmentWithMissingFileChangesNothing() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RenameMissingTests-\(UUID().uuidString)")
        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.calendar = Calendar(identifier: .gregorian)
        dayFormatter.dateFormat = "yyyy-MM-dd"
        let day = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        let dir = root.appendingPathComponent(dayFormatter.string(from: day), isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let mdURL = dir.appendingPathComponent("09-15-30.md")
        try ConversationMergerTests.partOne.write(to: mdURL, atomically: true, encoding: .utf8)

        let model = AppModel(
            assetInstaller: FakeAssetInstaller(installed: true), segmentRootOverride: root)
        await model.ensureSetUp()
        await model.loadInitialHistory()   // index now holds one entry, title nil
        #expect(model.historySections[0].index.segments[0].title == nil)

        // Delete the .md so applyTitle fails: the guard must stop the index from running
        // ahead of the (now missing) source of truth.
        try FileManager.default.removeItem(at: mdURL)
        await model.renameSegment(
            m4aURL: dir.appendingPathComponent("09-15-30.m4a"),
            title: "Ghost", startTime: Date())

        // Index title still nil — this FAILS if the applyTitle guard is removed, because
        // setTitle would then run despite the failed file write.
        #expect(model.historySections[0].index.segments[0].title == nil)
        #expect(await model.loadDayIndex(for: day)?.segments.first?.title == nil)
    }

    @Test func mergeSegmentsReturnsFalseWithoutChangesOnAbort() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MergeAbortTests-\(UUID().uuidString)")
        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.calendar = Calendar(identifier: .gregorian)
        dayFormatter.dateFormat = "yyyy-MM-dd"
        let day = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        let dir = root.appendingPathComponent(dayFormatter.string(from: day), isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try ConversationMergerTests.partOne.write(
            to: dir.appendingPathComponent("09-15-30.md"), atomically: true, encoding: .utf8)
        // Second entry's .md is MISSING → merger throws missingTranscript.

        let model = AppModel(
            assetInstaller: FakeAssetInstaller(installed: true), segmentRootOverride: root)
        await model.ensureSetUp()
        await model.loadInitialHistory()
        let section = model.historySections[0]
        let ghost = DaySegmentEntry(
            id: "10-01-00", startTime: Date(), duration: 120, backend: "speechAnalyzer",
            hasAudio: false, wordCount: 5, transcriptionState: "done")

        let ok = await model.mergeSegments(
            dayDirectory: section.dayDirectory,
            entries: section.index.segments + [ghost])

        #expect(!ok)
        #expect(model.historySections[0].index.segments.count == 1)   // unchanged
        let survivor = try String(
            contentsOf: dir.appendingPathComponent("09-15-30.md"), encoding: .utf8)
        #expect(!survivor.contains("gap"))
    }

    // MARK: - M12 Omi pairing composition

    private func omiModel(suiteSuffix: String, omiTransportOverride: (any OmiTransport)? = nil) -> AppModel {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmiModelTests-\(UUID().uuidString)")
        let suite = UserDefaults(suiteName: "omi-model-tests-\(suiteSuffix)-\(UUID().uuidString)")!
        return AppModel(
            assetInstaller: FakeAssetInstaller(installed: true), segmentRootOverride: root,
            omiStoreOverride: OmiDeviceStore(defaults: suite),
            omiTransportOverride: omiTransportOverride)
    }

    /// Task 10: pairing after setup has already completed rebuilds the pipeline in place
    /// (the pipeline is idle — never started) and surfaces the paired name immediately,
    /// without disturbing the already-idle pipeline's status.
    @Test func pairOmiAfterSetupRebuildsAndSurfacesPairedName() async throws {
        let model = omiModel(suiteSuffix: "pair-after-setup")
        await model.ensureSetUp()
        #expect(model.pipeline?.status == .idle)
        #expect(model.pairedOmiName == nil)

        let discovery = WearableDiscovery(id: UUID(), name: "Test Omi", rssi: -50, kind: .omi)
        await model.pairOmi(discovery)

        #expect(model.pairedOmiName == "Test Omi")
        #expect(model.pipeline?.status == .idle)   // rebuild kept it idle, didn't start it
    }

    /// Task 10: pairing BEFORE `ensureSetUp()` has ever run has no `recorder` to reuse yet —
    /// `rebuildPipelineIfIdle` must fall back to a full first-time `ensureSetUp()` rather
    /// than silently no-op, so the very first pairing (e.g. onboarding) still takes effect.
    @Test func pairOmiBeforeSetupBootstrapsFullSetup() async throws {
        let model = omiModel(suiteSuffix: "pair-before-setup")
        let discovery = WearableDiscovery(id: UUID(), name: "Early Omi", rssi: -40, kind: .omi)

        await model.pairOmi(discovery)

        #expect(model.pairedOmiName == "Early Omi")
        #expect(model.pipeline != nil)
        #expect(model.pipeline?.status == .idle)
    }

    /// Task 10: forgetting clears the paired name (via rebuild) and the battery/connection
    /// readings immediately, even though the rebuild that actually swaps the source is the
    /// same idle-gated path pairing uses.
    @Test func forgetOmiClearsPairedNameAndReadings() async throws {
        let model = omiModel(suiteSuffix: "forget")
        await model.ensureSetUp()
        await model.pairOmi(WearableDiscovery(id: UUID(), name: "Test Omi", rssi: -50, kind: .omi))
        #expect(model.pairedOmiName == "Test Omi")

        await model.forgetOmi()

        #expect(model.pairedOmiName == nil)
        #expect(model.omiBatteryLevel == nil)
        #expect(model.omiConnectionState == nil)
    }

    /// Task 10: no paired device ⇒ the plain phone-mic-only construction path — pairing is
    /// never exercised, so `pairedOmiName` stays nil and the pipeline is exactly the old
    /// single-source shape.
    @Test func noPairedDeviceKeepsPlainPhoneMicPath() async throws {
        let model = omiModel(suiteSuffix: "no-pairing")
        await model.ensureSetUp()

        #expect(model.pairedOmiName == nil)
        #expect(model.omiConnectionState == nil)
        #expect(model.omiBatteryLevel == nil)
        #expect(model.pipeline?.status == .idle)
    }

    /// Repeatedly emits `event` (harmless to redeliver — `OmiAudioSource.handle` is idempotent
    /// for `.connecting`/`.connected`) until `model.omiConnectionState == expected` or the
    /// timeout elapses. A single emit isn't reliable here: AppModel's observation loop
    /// (re-)subscribes from a detached `Task` inside `composePipeline`, not from a call the
    /// test directly awaits, so there's no guarantee the (re-)subscription has landed before
    /// one emit would arrive — unlike `FailoverAudioSource.start()`, which awaits
    /// `omi.connectionStates()` synchronously before returning.
    @discardableResult
    private func pollUntilConnectionState(
        _ expected: DeviceConnectionState, transport: FakeOmiTransport, event: OmiTransportEvent,
        model: AppModel, timeout: Duration = .seconds(1)
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            await transport.emit(event)
            try? await Task.sleep(for: .milliseconds(20))
            if model.omiConnectionState == expected { return true }
        }
        return model.omiConnectionState == expected
    }

    /// M12 final review Critical #1 regression: `OmiAudioSource.stop()` (called on every
    /// session stop, and on every park — including a phone-call interruption) finishes the
    /// `connectionStates()`/`batteryLevels()` streams `composePipeline` subscribed to exactly
    /// once. Before the fix, AppModel's observation tasks simply exited after the first stop —
    /// Settings status froze, the Bluetooth banner went stale, and the low-battery notification
    /// could never fire again for the rest of the process.
    ///
    /// Drives a real start→stop→start cycle through the actual composed pipeline (a real
    /// `FailoverAudioSource` over a real `OmiAudioSource`, fed by a `FakeOmiTransport` — no
    /// Bluetooth hardware) and asserts `omiConnectionState` updates again in the SECOND session.
    /// Paired BEFORE `ensureSetUp()` (rather than via a mid-test `pairOmi()`) so the pipeline is
    /// composed with the Omi failover branch from the start: `FailoverAudioSource.start()` only
    /// engages its real `PhoneMicAudioSource` fallback if the Omi hasn't streamed by the default
    /// 3 s startup race, or on a later disconnect — neither happens here, so both start/stop
    /// round-trips (bounded by `pollUntilConnectionState`'s 1 s timeout) never touch it. Real
    /// mic access is deliberately never exercised by any test in this suite (no test target
    /// microphone usage-description; requesting it here would risk a hard crash, not just a
    /// flaky permission prompt).
    @Test func omiStatusResubscribesAcrossSessions() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmiModelTests-\(UUID().uuidString)")
        let suite = UserDefaults(suiteName: "omi-model-tests-resubscribe-\(UUID().uuidString)")!
        let store = OmiDeviceStore(defaults: suite)
        store.pair(PairedOmiDevice(id: UUID(), name: "Resub Omi"))
        let transport = FakeOmiTransport()
        let model = AppModel(
            assetInstaller: FakeAssetInstaller(installed: true), segmentRootOverride: root,
            omiStoreOverride: store, omiTransportOverride: transport)
        await model.ensureSetUp()
        #expect(model.pairedOmiName == "Resub Omi")
        #expect(model.pipeline?.status == .idle)

        // First session.
        await model.pipeline?.start()
        let sawFirst = await pollUntilConnectionState(
            .connecting, transport: transport, event: .connecting, model: model)
        #expect(sawFirst, "setup: omiConnectionState never reflected the first session's .connecting")

        await model.pipeline?.stop()
        #expect(model.pipeline?.status == .idle)

        // Second session: without the re-subscribe loop, the observation task exited when the
        // first stop() finished the stream — this would never update again.
        await model.pipeline?.start()
        let sawSecond = await pollUntilConnectionState(
            .connected, transport: transport,
            event: .connected(codecValue: OmiConstants.codecPCM16at16kHz), model: model)
        #expect(sawSecond, "omiConnectionState never updated again in the second session — observation died after the first stop")

        await model.pipeline?.stop()
    }

    /// M12 final review Important #2 regression: a mid-session pairing change must (a) surface
    /// in Settings immediately (not silently wait for `composePipeline`, which only re-runs on
    /// an idle rebuild) and (b) actually recompose the pipeline once that session ends, with no
    /// relaunch required.
    ///
    /// Exercises the FORGET direction (paired→unpaired) rather than pair-while-on-plain-mic:
    /// starting unpaired would compose the plain-phone-mic branch, and starting THAT pipeline
    /// means a real, un-faked `PhoneMicAudioSource.start()` — the one real-mic path this whole
    /// suite deliberately never takes (see `omiStatusResubscribesAcrossSessions`). Forgetting
    /// exercises the exact same shared code (`pairedOmiName` immediate-update fix +
    /// `stopListening()` → `rebuildIfSourceShapeChanged()`), just via the opposite transition,
    /// with the session itself safely staying on the fake-transport-backed Omi source the whole
    /// time (never falling back to the real mic within the test's short window — see above).
    @Test func forgetWhileListeningClearsNameImmediatelyAndRebuildsOnStop() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmiModelTests-\(UUID().uuidString)")
        let suite = UserDefaults(suiteName: "omi-model-tests-forget-live-\(UUID().uuidString)")!
        let store = OmiDeviceStore(defaults: suite)
        store.pair(PairedOmiDevice(id: UUID(), name: "Live Omi"))
        let transport = FakeOmiTransport()
        let model = AppModel(
            assetInstaller: FakeAssetInstaller(installed: true), segmentRootOverride: root,
            omiStoreOverride: store, omiTransportOverride: transport)
        await model.ensureSetUp()
        let originalPipeline = model.pipeline
        #expect(model.composedWithOmi == true)

        await model.pipeline?.start()
        #expect(model.pipeline?.status != .idle)

        await model.forgetOmi()

        // (a) Settings truth updates right away, mid-session — before this fix, `pairedOmiName`
        // only ever changed inside `composePipeline`, so it would still read "Live Omi" here.
        #expect(model.pairedOmiName == nil)
        // Rebuild is deferred: still the same pipeline instance, still composed WITH Omi.
        #expect(model.pipeline === originalPipeline)
        #expect(model.composedWithOmi == true)

        // (b) Ending the session (the Home screen's Stop path, via `stopListening()`) picks up
        // the deferred rebuild — no relaunch required.
        await model.stopListening()

        #expect(model.pipeline?.status == .idle)
        #expect(model.composedWithOmi == false)
        #expect(model.pipeline !== originalPipeline)
    }
}

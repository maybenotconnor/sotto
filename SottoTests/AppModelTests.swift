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
}

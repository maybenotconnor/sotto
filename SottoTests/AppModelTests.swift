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
}

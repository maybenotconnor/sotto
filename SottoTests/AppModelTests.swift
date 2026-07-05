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
}

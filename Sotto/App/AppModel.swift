import SwiftUI
import UIKit

/// Scene-independent home for the pipeline and its setup wiring. Unlike a View's @State,
/// this survives scene teardown/recreation and — critically — exists independently of any
/// scene at all: a cold background launch driven by the Live Activity intent runs with NO
/// scene/ContentView instantiated, so setup and the intent handler must live here, not in
/// ContentView (M3 review Critical #2).
@MainActor
@Observable
final class AppModel {
    enum AssetState: Equatable {
        case unknown
        case installed
        case notInstalled
        case downloading(Double)
        case failed(String)
        /// Simulator or non-Apple-Intelligence hardware: on-device transcription cannot ever
        /// run here, so this is NOT a download failure — no retry/download affordance shown.
        case unsupported
    }

    /// M9 unified home: one day's worth of history — a loaded page's unit. `index` is kept
    /// in sync by `refreshLoadedHistory()` (re-read after a finalize/delete) rather than
    /// re-derived on every access.
    struct HistorySection: Identifiable, Equatable {
        let id: String          // "2026-03-14" (day folder name)
        let date: Date          // parsed day start (local)
        let dayDirectory: URL
        var index: DayIndex
    }

    /// M6b Settings "Storage" section: on-disk footprint split by kind, walked live rather
    /// than tracked incrementally (this repo's file counts are small; a full walk is cheap
    /// and can never drift from the true on-disk state).
    struct StorageUsage: Equatable {
        let audioMB: Double
        let transcriptKB: Double
    }

    private(set) var pipeline: ListeningPipeline?
    private(set) var setupError: String?
    private(set) var recoveryNotice: String?
    private(set) var queue: TranscriptionQueue?
    private(set) var dayIndex: DayIndexStore?
    private(set) var assetState: AssetState = .unknown
    /// M9 unified home: the loaded window of history, newest day first.
    private(set) var historySections: [HistorySection] = []
    /// True while unvisited day directories remain under `segmentRoot` (paging isn't
    /// exhausted yet).
    private(set) var hasMoreHistory = false
    let settings = SettingsStore()
    private var setupTask: Task<Void, Never>?
    private var observer: AudioSessionObserver?
    private let installer: any SpeechAssetInstalling
    private let networkMonitor: any NetworkMonitoring
    /// Test seam: when set, `performSetUp` roots BOTH the `SegmentStore` and `segmentRoot`
    /// here instead of the real Documents/Sotto directory, so history paging and the
    /// `DayIndexStore` operate purely on a synthetic directory tree.
    private let segmentRootOverride: URL?
    // Default mirrors SegmentStore's own default root; overwritten with the real
    // `store.rootDirectory` during performSetUp once `store` exists.
    private var segmentRoot: URL = FileManager.default.urls(
        for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Sotto", isDirectory: true)
    /// Directory names (newest first) not yet consumed by history paging — populated fresh by
    /// `loadInitialHistory()`, drained 7-content-days-at-a-time by `loadNextHistoryPage()`.
    private var pendingHistoryDirectoryNames: [String] = []

    /// Pinned "yyyy-MM-dd" formatter (POSIX locale, Gregorian calendar) shared by history
    /// paging and `dayDirectory(for:)` — folder names must not drift with the user's
    /// locale/calendar settings (SPEC "File output" store layout).
    private static let dayFolderFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    init(
        assetInstaller: (any SpeechAssetInstalling)? = nil,
        networkMonitor: (any NetworkMonitoring)? = nil,
        segmentRootOverride: URL? = nil
    ) {
        self.installer = assetInstaller ?? SpeechAssetInstaller()
        self.networkMonitor = networkMonitor ?? WiFiMonitor()
        self.segmentRootOverride = segmentRootOverride
        // Registered synchronously so a cold background launch (the intent runs the app
        // process without a scene) can already await a real toggle the moment perform() runs.
        IntentHandlers.shared.register(owner: self) { [weak self] in
            await self?.toggleFromIntent()
        }
    }

    /// Requests + downloads the on-device speech model (SPEC "Model assets"). Entry is
    /// allowed from `.notInstalled` (first run / never downloaded) OR `.failed` (retry after
    /// a prior download error) — any other state (already `.installed`, mid-`.downloading`,
    /// or `.unknown` before setup) is a no-op.
    func downloadSpeechModel() async {
        switch assetState {
        case .notInstalled, .failed: break
        default: return
        }
        assetState = .downloading(0)
        do {
            try await installer.install { [weak self] fraction in
                Task { @MainActor [weak self] in
                    if case .downloading = self?.assetState { self?.assetState = .downloading(fraction) }
                }
            }
            assetState = .installed
            if let queue { Task { await queue.drain() } }   // pending jobs can proceed now
        } catch {
            // Simulator/non-Apple-Intelligence hardware: this is NOT a network failure — the
            // UI must not blame the connection for something no retry can ever fix.
            if let installerError = error as? SpeechAssetInstaller.InstallerError,
               installerError == .unsupportedDevice {
                assetState = .unsupported
            } else {
                assetState = .failed(String(describing: error))
            }
        }
    }

    /// M9 unified home: resets paging and loads the first 7-content-day page, newest first.
    func loadInitialHistory() async {
        historySections = []
        pendingHistoryDirectoryNames = sortedHistoryDirectoryNames()
        await loadNextHistoryPage()
    }

    /// M9 unified home: appends the next 7-content-day page — a no-op once paging is
    /// exhausted (`hasMoreHistory == false`).
    func loadMoreHistory() async {
        guard hasMoreHistory else { return }
        await loadNextHistoryPage()
    }

    /// M9 unified home: re-reads `_day.json` for every already-loaded section (called where
    /// `refreshTodaySummary()` used to be — a finalize, delete, or scenePhase-active event),
    /// and prepends today's section if it now has content and isn't already loaded (a day
    /// with no folder yet at launch never entered the initial page).
    func refreshLoadedHistory() async {
        var refreshed: [HistorySection] = []
        for section in historySections {
            guard let index = await loadDayIndex(dayDirectory: section.dayDirectory) else { continue }
            refreshed.append(HistorySection(
                id: section.id, date: section.date, dayDirectory: section.dayDirectory, index: index))
        }
        historySections = refreshed

        let todayName = Self.dayFolderFormatter.string(from: Date())
        guard !historySections.contains(where: { $0.id == todayName }) else { return }
        if let today = await historySection(forDayName: todayName) {
            historySections.insert(today, at: 0)
        }
    }

    /// Drains `pendingHistoryDirectoryNames` from the front until either 7 content-days have
    /// been collected or the pending list is exhausted — empty/gap-less day folders are
    /// consumed from the list but contribute no section (SPEC: paging counts CONTENT days).
    private func loadNextHistoryPage() async {
        var page: [HistorySection] = []
        while !pendingHistoryDirectoryNames.isEmpty, page.count < 7 {
            let name = pendingHistoryDirectoryNames.removeFirst()
            if let section = await historySection(forDayName: name) {
                page.append(section)
            }
        }
        historySections.append(contentsOf: page)
        hasMoreHistory = !pendingHistoryDirectoryNames.isEmpty
    }

    /// Builds a `HistorySection` for the day folder named `name` (e.g. "2026-03-14"), or nil
    /// when the name doesn't parse or the day has no segments/gaps (SPEC: paging skips
    /// content-less days).
    private func historySection(forDayName name: String) async -> HistorySection? {
        guard let date = Self.dayFolderFormatter.date(from: name) else { return nil }
        let dir = segmentRoot.appendingPathComponent(name, isDirectory: true)
        guard let index = await loadDayIndex(dayDirectory: dir),
              !index.segments.isEmpty || !index.gaps.isEmpty
        else { return nil }
        return HistorySection(id: name, date: date, dayDirectory: dir, index: index)
    }

    /// Day folder names directly under `segmentRoot` matching `yyyy-MM-dd`, sorted newest
    /// first (a plain string sort is date-order-equivalent for this fixed-width format).
    private func sortedHistoryDirectoryNames() -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: segmentRoot.path)
        else { return [] }
        return names.filter { $0.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil }
            .sorted(by: >)
    }

    /// M6b Main screen: lets the user clear the crash-recovery banner without waiting for
    /// the next launch to age it out.
    func dismissRecoveryNotice() {
        recoveryNotice = nil
    }

    /// SPEC "File output" store layout: the folder a given local day's segments live under.
    func dayDirectory(for date: Date) -> URL {
        segmentRoot.appendingPathComponent(Self.dayFolderFormatter.string(from: date))
    }

    /// History List's day navigator: loads `_day.json` for `date`, rebuilding-and-persisting
    /// it from the folder's `.md` frontmatter when the file is missing/corrupt but the day
    /// folder itself exists (SPEC: the index is rebuildable). A day with no folder at all
    /// (never recorded) returns nil rather than fabricating an empty index.
    func loadDayIndex(for date: Date) async -> DayIndex? {
        await loadDayIndex(dayDirectory: dayDirectory(for: date))
    }

    /// M9: the paging-friendly variant of `loadDayIndex(for:)` that `loadDayIndex(for:)` now
    /// calls — takes a day folder directly rather than deriving one from a `Date`, since
    /// history paging enumerates folder names first and only parses a `Date` afterward.
    private func loadDayIndex(dayDirectory dir: URL) async -> DayIndex? {
        guard let dayIndex else { return nil }
        if let existing = await dayIndex.index(forDay: dir) { return existing }
        guard FileManager.default.fileExists(atPath: dir.path) else { return nil }
        return await dayIndex.rebuildAndPersist(dayDirectory: dir)
    }

    /// Failed-row retry (List/Detail "Transcription failed — retry").
    func retryTranscription(m4aURL: URL) async {
        if let queue { await queue.retry(m4aURL: m4aURL) }
    }

    /// Detail view "Re-transcribe with current backend": replaces any existing job for this
    /// URL with a fresh one and redrives it (see `TranscriptionQueue.retranscribe`).
    func retranscribe(m4aURL: URL) async {
        if let queue { await queue.retranscribe(m4aURL: m4aURL) }
    }

    /// Row deletion (List swipe / Detail button). Both files are removed best-effort — a
    /// partial state (e.g. the .m4a already gone under `deleteAfterTranscription` retention,
    /// leaving only the .md) must not block the rest of the cleanup — then the queue/index
    /// entries are dropped, then the loaded history re-derives from the now-updated index.
    func deleteSegment(m4aURL: URL) async {
        let mdURL = m4aURL.deletingPathExtension().appendingPathExtension("md")
        try? FileManager.default.removeItem(at: m4aURL)
        try? FileManager.default.removeItem(at: mdURL)
        await queue?.removeJob(m4aURL: m4aURL)
        await dayIndex?.removeSegment(m4aURL: m4aURL)
        PreviewCache.shared.invalidate(mdURL: mdURL)
        await refreshLoadedHistory()
    }

    /// M6b Settings "Storage" section: walks `segmentRoot` summing audio (.m4a/.caf) bytes
    /// separately from transcript (.md/_day.json) bytes. Missing/unreadable file sizes count
    /// as 0 rather than failing the whole walk.
    func storageUsage() -> StorageUsage {
        var audioBytes = 0
        var transcriptBytes = 0
        if let enumerator = FileManager.default.enumerator(
            at: segmentRoot, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let url as URL in enumerator {
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                switch url.pathExtension {
                case "m4a", "caf": audioBytes += size
                case "md", "json": transcriptBytes += size
                default: break
                }
            }
        }
        return StorageUsage(
            audioMB: Double(audioBytes) / 1_048_576,
            transcriptKB: Double(transcriptBytes) / 1024)
    }

    /// M6b Settings "Test key": exercises the candidate Deepgram key against a real ~1 s
    /// sample (0.5 s of silence, encoded exactly like a real segment) rather than trusting
    /// key *format* — the only way to know a BYOK key actually works is to use it. Real
    /// network call: user-initiated only (the Settings "Test key" button), never invoked
    /// from setup or from tests.
    func testDeepgramKey(_ key: String) async -> Bool {
        let tmp = FileManager.default.temporaryDirectory
        let cafURL = tmp.appendingPathComponent("\(UUID().uuidString).caf")
        let m4aURL = tmp.appendingPathComponent("\(UUID().uuidString).m4a")
        defer {
            try? FileManager.default.removeItem(at: cafURL)
            try? FileManager.default.removeItem(at: m4aURL)
        }
        do {
            let writer = try CAFSegmentWriter(cafURL: cafURL, m4aURL: m4aURL)
            // 0.5 s of silence @ VADConstants.sampleRate (8000 samples at 16 kHz).
            try writer.append([Float](repeating: 0, count: Int(0.5 * Double(VADConstants.sampleRate))))
            writer.close()
            try CAFSegmentWriter.transcodeToM4A(caf: cafURL, m4a: m4aURL)
            _ = try await DeepgramService(apiKeyProvider: { key }).transcribe(file: m4aURL)
            return true
        } catch {
            return false
        }
    }

    func toggleFromIntent() async {
        await ensureSetUp()
        await pipeline?.toggleFromIntent()
    }

    /// A Live Activity toggle that arrives mid-setup AWAITS the same in-flight setup
    /// instead of no-opping against a nil pipeline (review finding) — the shared `Task`
    /// makes every caller (this one and any concurrent one) observe the same completion.
    func ensureSetUp() async {
        if setupTask == nil {
            setupTask = Task { await performSetUp() }
        }
        await setupTask?.value
    }

    @MainActor
    private func performSetUp() async {
        guard let modelURL = Bundle.main.url(
            forResource: SileroSpeechDetector.modelResourceName,
            withExtension: "mlmodelc")
        else {
            setupError = "VAD model missing from app bundle"
            return
        }

        // Test seam: when set, `segmentRootOverride` roots BOTH the store and the DayIndexStore
        // on a synthetic directory tree, so history paging and rebuilds never touch the real
        // Documents/Sotto folder.
        let store = SegmentStore(rootDirectory: segmentRootOverride)
        self.segmentRoot = store.rootDirectory
        let dayIndexStore = DayIndexStore(rootDirectory: segmentRootOverride)
        self.dayIndex = dayIndexStore
        let heartbeat = HeartbeatStore()
        // Copied to a local (Sendable struct) rather than captured as `self.settings` inside
        // the Sendable closures below — avoids pulling the MainActor-isolated `self` into
        // nonisolated contexts. Settings changes apply on the NEXT Start/launch (SPEC
        // "changes affect only future segments"), not to a session already in progress.
        let settings = self.settings

        // Unconditional launch sweep (SPEC "Recording writer"): a failed finalize can leave
        // a CAF behind even after a clean shutdown. No-op when nothing is orphaned.
        // Wiring-order invariant: salvage MUST complete before the recorder/writer below
        // can exist — it transcodes every .caf under the root.
        let salvaged = await Task.detached { OrphanSalvager.salvage(store: store) }.value

        // Constructed early so leftover activities from a previous process (iOS keeps them
        // up to 8 h after a kill) are ended right away, before anything else stands up.
        let liveActivity = SottoLiveActivityController()
        liveActivity.endAllStale()

        // The banner stays gated on the heartbeat (a crash), not on salvage results alone.
        if heartbeat.indicatesUncleanShutdown {
            // Capture the heartbeat's timestamp BEFORE clearing it below — it's the last
            // moment listening was known-alive, i.e. the spec's `gap` entry (SPEC "Unclean
            // shutdown detection"). Read here rather than trust `indicatesUncleanShutdown`'s
            // own internal read, since that one doesn't hand the timestamp back.
            if let beat = heartbeat.read() {
                await dayIndexStore.recordGap(
                    onDayOf: beat.timestamp, from: beat.timestamp, reason: "uncleanShutdown")
            }
            recoveryNotice = salvaged.isEmpty
                ? "Listening stopped unexpectedly last session."
                : "Listening stopped unexpectedly — recovered \(salvaged.count) unfinished recording(s)."
            heartbeat.clear()
        }

        do {
            // CoreML load/compile can take hundreds of ms (seconds on a cold cache) —
            // off the MainActor so the loading indicator actually renders and animates.
            let detector = try await Task.detached(priority: .userInitiated) {
                try SileroSpeechDetector(modelURL: modelURL, threshold: settings.vadThreshold)
            }.value
            var config = RecorderConfig()
            config.silenceTimeout = settings.silenceTimeout
            config.minSegmentSpeechDuration = settings.minSegmentSpeech
            // max(1, ...): guards RecorderStateMachine's `preRollCapacity > 0` precondition —
            // a 0 or negative preRollSeconds (bad UserDefaults value, M6b UI bug) must not
            // crash setup.
            config.preRollCapacity = max(1, Int(settings.preRollSeconds * Double(VADConstants.sampleRate)))
            let recorder = RecorderStateMachine(
                detector: detector,
                writerFactory: CAFSegmentWriterFactory(store: store),
                store: store,
                config: config)

            // Backend selection: on-device by default; Deepgram only when the Settings toggle
            // is on AND a key exists (full Settings toggle is M6b's UI; the toggle plus the
            // key gate both live here). Resolved fresh PER JOB (the queue calls this closure
            // inside `step`, not once at construction) so a Deepgram key added or the toggle
            // flipped mid-session hot-swaps the backend for future segments only, without
            // reconstructing the queue (SPEC "changes affect only future segments").
            let keychain = KeychainStore()
            // Local (not `self.networkMonitor`) for the same reason as `settings` above:
            // keeps the MainActor-isolated `self` out of this nonisolated, @Sendable closure.
            let monitor = networkMonitor
            let transcriptionQueue = TranscriptionQueue(
                serviceProvider: {
                    if settings.deepgramEnabled, keychain.get("deepgramAPIKey") != nil {
                        let deepgram = DeepgramService(apiKeyProvider: { KeychainStore().get("deepgramAPIKey") })
                        // Wi-Fi gate (M6b): reuses the existing environmental classification
                        // (`.unavailable` → job stays pending, drain stops) rather than adding a
                        // new one — see NetworkMonitoring.swift.
                        return WiFiGatedService(inner: deepgram, allowed: { !settings.wifiOnlyUpload || monitor.isOnWiFi })
                    } else {
                        return SpeechAnalyzerService()
                    }
                },
                // M8 post-processing: on-device meeting notes only when Apple Intelligence is
                // actually available on this device — never a download/setup affordance,
                // never blocks a job (best-effort inside the queue itself).
                postProcessorProvider: {
                    // SPEC Low Power detection — skip ANE-heavy notes generation while Low
                    // Power Mode is on; transcripts still ship, only the best-effort notes
                    // are skipped for this job.
                    guard !ProcessInfo.processInfo.isLowPowerModeEnabled else { return nil }
                    return FoundationModelsPostProcessor.isModelAvailable ? FoundationModelsPostProcessor() : nil
                })
            self.queue = transcriptionQueue

            // Fix 3: salvaged audio must be transcribed, not just recovered. Enqueued
            // BEFORE the gated drain decision below — on an asset-less device these jobs
            // wait as `.pending` just like any other (Fix 1 keeps that safe).
            //
            // Ordering invariant (M5 hardening #4): this loop calls enqueueSalvaged THEN
            // recordQueuedSegment per job — inverted vs the live segment-handler path below
            // (index-entry-before-job), but safe: nothing can drain the queue mid-loop.
            // `setTransitionHandler` isn't installed until after this loop, and the launch
            // drain `Task` is only kicked off later, after the onDeviceReady/hasDeepgramKey
            // check further down — both strictly after this `for` loop has fully awaited
            // every iteration. If this loop is ever restructured to spawn concurrent work
            // (e.g. a `Task` per url), re-derive this invariant or record-before-enqueue.
            for url in salvaged {
                if let job = await transcriptionQueue.enqueueSalvaged(m4aURL: url) {
                    await dayIndexStore.recordQueuedSegment(
                        m4aURL: job.m4aURL, startTime: job.startDate, duration: job.duration)
                }
            }

            await recorder.setSegmentHandler { segment in
                Task {
                    await dayIndexStore.recordQueuedSegment(
                        m4aURL: segment.m4aURL,
                        startTime: segment.startDate,
                        duration: segment.duration)
                    await transcriptionQueue.enqueue(segment)
                    await transcriptionQueue.drain()
                }
            }

            let source = PhoneMicAudioSource()
            let newPipeline = ListeningPipeline(
                source: source, recorder: recorder, heartbeat: heartbeat,
                liveActivity: liveActivity,
                notifications: UserNotificationScheduler())
            pipeline = newPipeline

            let sessionObserver = AudioSessionObserver(backgroundTasks: UIKitBackgroundTasks())
            sessionObserver.onInterruptionBegan = { [weak newPipeline] in
                await newPipeline?.interrupt()
            }
            sessionObserver.onInterruptionEndedShouldResume = { [weak newPipeline] shouldResume in
                // Foregrounded + system says resume → restart. Backgrounded: engine.start()
                // fails (561145187); recovery stays with the intent/notification/app-open.
                guard shouldResume, UIApplication.shared.applicationState == .active else { return }
                await newPipeline?.resumeFromInterruption()
            }
            sessionObserver.onRouteChangeDeviceUnavailable = { [weak source, weak newPipeline] in
                do {
                    try await source?.rebuildTap()
                } catch {
                    // No valid input route: park honestly instead of silently losing capture.
                    await newPipeline?.interrupt()
                }
            }
            sessionObserver.onMediaServicesReset = { [weak newPipeline] in
                // Full teardown + rebuild (SPEC): park, then restart the whole stack.
                await newPipeline?.interrupt()
                // Backgrounded: engine.start() fails (561145187); recovery stays with the
                // intent/notification/app-open, and interrupt() already scheduled the fallback.
                guard UIApplication.shared.applicationState == .active else { return }
                await newPipeline?.resumeFromInterruption()
            }
            sessionObserver.startObserving()
            observer = sessionObserver

            // Terminal transitions (done/failed) drive the day index and the retention
            // policy (SPEC "File output" retention: audio deleted after transcription by
            // default; transcripts are never touched here). Synchronous @Sendable — the
            // queue actor must not be re-entered mid-notification — so each side effect is
            // dispatched into its own Task.
            await transcriptionQueue.setTransitionHandler { transition in
                Task {
                    let wordCount = transition.result.map {
                        $0.text.split { $0.isWhitespace || $0.isNewline }.count
                    }
                    // Keep-stale by design: a re-transcription that yields no notes keeps the
                    // previous title (friendlier than clearing); a rebuild from files drops
                    // it — acceptable divergence.
                    await dayIndexStore.updateSegment(
                        m4aURL: transition.job.m4aURL,
                        transcriptionState: transition.job.state.rawValue,
                        backend: transition.result?.backend.rawValue,
                        wordCount: wordCount,
                        title: transition.notes?.title)
                    if transition.job.state == .done,
                       RetentionEnforcer.applyAfterTranscription(
                           m4aURL: transition.job.m4aURL, retention: settings.audioRetention) {
                        await dayIndexStore.setAudioRemoved(m4aURL: transition.job.m4aURL)
                    }
                }
            }

            // Leftovers from the previous run drain at launch (SPEC); the resume path is
            // unnecessary since drain is also kicked per enqueue. Gate on backend
            // availability so a fresh offline install doesn't burn attempts on jobs that
            // can't possibly succeed yet (M6 adds the download UI + drain gating).
            // Simulator/non-Apple-Intelligence hardware never gets a download affordance —
            // no download can ever succeed there, so `.unsupported` short-circuits the
            // installed/notInstalled check entirely (M6b follow-up: truthful failure states).
            let deviceSupported = await installer.deviceSupported()
            let assetsInstalled = await installer.assetsInstalled()
            let onDeviceReady = deviceSupported && assetsInstalled
            assetState = !deviceSupported ? .unsupported : (onDeviceReady ? .installed : .notInstalled)
            let hasDeepgramKey = settings.deepgramEnabled && keychain.get("deepgramAPIKey") != nil
            if onDeviceReady || hasDeepgramKey {
                Task { await transcriptionQueue.drain() }
            } else if deviceSupported {
                let notice = "Transcription model not installed — recordings are kept and will be transcribed later."
                recoveryNotice = recoveryNotice.map { "\($0)\n\(notice)" } ?? notice
            }

            // Launch retention sweep (keepSevenDays only; a no-op under the other policies).
            // Fire-and-forget: nothing else waits on it. Scoped to the SegmentStore's own
            // root (Documents/Sotto), NEVER bare Documents — Documents is Files-app-writable,
            // so a broader sweep risks deleting files the user placed there themselves.
            Task.detached {
                let swept = RetentionEnforcer.sweep(
                    root: store.rootDirectory, retention: settings.audioRetention)
                for url in swept {
                    await dayIndexStore.setAudioRemoved(m4aURL: url)
                }
            }
        } catch {
            setupError = String(describing: error)
        }
    }
}

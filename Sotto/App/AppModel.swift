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
    }

    /// SPEC Main screen "today summary": conversation count + total minutes for the
    /// current local day.
    struct TodaySummary: Equatable {
        let count: Int
        let totalMinutes: Double
    }

    private(set) var pipeline: ListeningPipeline?
    private(set) var setupError: String?
    private(set) var recoveryNotice: String?
    private(set) var queue: TranscriptionQueue?
    private(set) var dayIndex: DayIndexStore?
    private(set) var assetState: AssetState = .unknown
    private(set) var todaySummary: TodaySummary?
    let settings = SettingsStore()
    private var setupTask: Task<Void, Never>?
    private var observer: AudioSessionObserver?
    private let installer: any SpeechAssetInstalling
    private let networkMonitor: any NetworkMonitoring
    // Default mirrors SegmentStore's own default root; overwritten with the real
    // `store.rootDirectory` during performSetUp once `store` exists.
    private var segmentRoot: URL = FileManager.default.urls(
        for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Sotto", isDirectory: true)

    init(
        assetInstaller: (any SpeechAssetInstalling)? = nil,
        networkMonitor: (any NetworkMonitoring)? = nil
    ) {
        self.installer = assetInstaller ?? SpeechAssetInstaller()
        self.networkMonitor = networkMonitor ?? WiFiMonitor()
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
            assetState = .failed(String(describing: error))
        }
    }

    /// SPEC Main screen "today summary": re-derived from `_day.json` for the current local
    /// day whenever the pipeline finalizes a new segment (Main screen calls this via
    /// `.task(id: pipeline.finalizedCount)`).
    func refreshTodaySummary() async {
        guard let dayIndex else { return }
        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.calendar = Calendar(identifier: .gregorian)
        dayFormatter.dateFormat = "yyyy-MM-dd"
        let dayDirectory = segmentRoot.appendingPathComponent(dayFormatter.string(from: Date()))
        guard let index = await dayIndex.index(forDay: dayDirectory), !index.segments.isEmpty else {
            todaySummary = nil
            return
        }
        todaySummary = TodaySummary(
            count: index.segments.count,
            totalMinutes: index.segments.reduce(0) { $0 + $1.duration } / 60)
    }

    /// M6b Main screen: lets the user clear the crash-recovery banner without waiting for
    /// the next launch to age it out.
    func dismissRecoveryNotice() {
        recoveryNotice = nil
    }

    /// Row deletion (List swipe / Detail button). Both files are removed best-effort — a
    /// partial state (e.g. the .m4a already gone under `deleteAfterTranscription` retention,
    /// leaving only the .md) must not block the rest of the cleanup — then the queue/index
    /// entries are dropped, then the summary re-derives from the now-updated index.
    func deleteSegment(m4aURL: URL) async {
        let mdURL = m4aURL.deletingPathExtension().appendingPathExtension("md")
        try? FileManager.default.removeItem(at: m4aURL)
        try? FileManager.default.removeItem(at: mdURL)
        await queue?.removeJob(m4aURL: m4aURL)
        await dayIndex?.removeSegment(m4aURL: m4aURL)
        await refreshTodaySummary()
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

        let store = SegmentStore()
        self.segmentRoot = store.rootDirectory
        let dayIndexStore = DayIndexStore()
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
            let transcriptionQueue = TranscriptionQueue(serviceProvider: {
                if settings.deepgramEnabled, keychain.get("deepgramAPIKey") != nil {
                    let deepgram = DeepgramService(apiKeyProvider: { KeychainStore().get("deepgramAPIKey") })
                    // Wi-Fi gate (M6b): reuses the existing environmental classification
                    // (`.unavailable` → job stays pending, drain stops) rather than adding a
                    // new one — see NetworkMonitoring.swift.
                    return WiFiGatedService(inner: deepgram, allowed: { !settings.wifiOnlyUpload || monitor.isOnWiFi })
                } else {
                    return SpeechAnalyzerService()
                }
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
                    await dayIndexStore.updateSegment(
                        m4aURL: transition.job.m4aURL,
                        transcriptionState: transition.job.state.rawValue,
                        backend: transition.result?.backend.rawValue,
                        wordCount: wordCount)
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
            let onDeviceReady = await installer.assetsInstalled()
            assetState = onDeviceReady ? .installed : .notInstalled
            let hasDeepgramKey = settings.deepgramEnabled && keychain.get("deepgramAPIKey") != nil
            if onDeviceReady || hasDeepgramKey {
                Task { await transcriptionQueue.drain() }
            } else {
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

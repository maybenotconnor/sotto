import os
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

    /// Merge-conversations selection gating (spec 2026-07-06). Selection keys are
    /// "<sectionID>/<entryID>" — entry ids (HH-mm-ss) are only unique within one day, so
    /// the key carries the day. Stale keys (row deleted mid-selection) are ignored.
    enum MergeEligibility: Equatable {
        case eligible(dayDirectory: URL, entries: [DaySegmentEntry])
        case tooFew
        case multipleDays
        case notAllDone
    }

    nonisolated static func mergeEligibility(
        selectedKeys: Set<String>, sections: [HistorySection]
    ) -> MergeEligibility {
        var picked: [(section: HistorySection, entry: DaySegmentEntry)] = []
        for section in sections {
            for entry in section.index.segments
            where selectedKeys.contains("\(section.id)/\(entry.id)") {
                picked.append((section, entry))
            }
        }
        guard picked.count >= 2 else { return .tooFew }
        guard Set(picked.map(\.section.id)).count == 1 else { return .multipleDays }
        guard picked.allSatisfy({ $0.entry.transcriptionState == "done" }) else {
            return .notAllDone
        }
        let entries = picked.map(\.entry).sorted { ($0.startTime, $0.id) < ($1.startTime, $1.id) }
        return .eligible(dayDirectory: picked[0].section.dayDirectory, entries: entries)
    }

    /// M12 Task 12 (home banner): the Bluetooth-off/unauthorized banner shows only when an
    /// Omi is actually paired (unpaired users never see Bluetooth chatter) AND the reason is
    /// one the user can act on via Settings — `.unsupported` has no Settings toggle to fix,
    /// so it's deliberately excluded here (Settings' `deviceStatusLabel` still surfaces it as
    /// status text, just not as an actionable banner).
    nonisolated static func bluetoothBannerReason(
        pairedDeviceName: String?, connectionState: DeviceConnectionState?
    ) -> BluetoothUnavailableReason? {
        guard pairedDeviceName != nil, case .unavailable(let reason) = connectionState,
              reason == .poweredOff || reason == .unauthorized
        else { return nil }
        return reason
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
    /// Flips true once `loadInitialHistory()` has completed its first pass. Gates the
    /// "nothing recorded yet" empty state so a quiet, spinner-less launch (or a
    /// pull-to-refresh) never flashes that copy while the first real page is still loading.
    private(set) var hasLoadedHistoryOnce = false
    /// Set after a launch or manual iCloud restore actually added transcripts — surfaced as a
    /// small status line on the home screen and cleared when the user dismisses it. nil =
    /// nothing restored / not run yet.
    private(set) var restoreStatus: String?
    let settings = SettingsStore()
    private var setupTask: Task<Void, Never>?
    private var observer: AudioSessionObserver?
    private let installer: any SpeechAssetInstalling
    private let networkMonitor: any NetworkMonitoring
    /// Test seam: when set, `performSetUp` roots BOTH the `SegmentStore` and `segmentRoot`
    /// here instead of the real Documents/Sotto directory, so history paging and the
    /// `DayIndexStore` operate purely on a synthetic directory tree.
    private let segmentRootOverride: URL?
    /// Test seam mirroring `segmentRootOverride`: when set, device pairing reads/writes
    /// this store instead of `UserDefaults.standard`.
    private let deviceStoreOverride: PairedDeviceStore?
    /// Test seam mirroring `deviceStoreOverride`: when set, the factory's `.omi` branch in
    /// `composePipeline` builds `OmiAudioSource` over this transport instead of a real
    /// `CoreBluetoothOmiTransport` — lets tests drive connection/battery events (e.g. the
    /// Critical #1 re-subscribe-across-sessions regression test) with no Bluetooth hardware
    /// involved. Kept Omi-named: it is typed `any OmiTransport`, genuinely Omi-specific.
    private let omiTransportOverride: (any OmiTransport)?
    /// M12: the long-lived recorder built once in `performSetUp` — reused (not
    /// reconstructed) by `rebuildPipelineIfIdle()` so a pair/forget mid-app-life doesn't pay
    /// for a second CoreML detector load and, more importantly, doesn't stand up a second
    /// `TranscriptionQueue`/`DayIndexStore` racing the originals over the same persisted
    /// files (see `composePipeline`).
    private var recorder: RecorderStateMachine?
    /// M12 pairing (Settings, Task 11): the currently paired wearable's advertised
    /// peripheral name, or nil.
    private(set) var pairedDeviceName: String?
    /// The paired wearable's family — drives banner/notification copy (the family
    /// display name isn't derivable from `pairedDeviceName`). Set and cleared together
    /// with `pairedDeviceName` everywhere.
    private(set) var pairedDeviceKind: DeviceKind?
    /// M12 final review Important #2: whether the CURRENTLY COMPOSED pipeline's source
    /// includes the wearable failover branch — i.e. what `composePipeline` last built, as opposed
    /// to `deviceStoreOverride`'s (or the real store's) present pairing state, which a mid-session
    /// pair/forget can move out ahead of. `rebuildIfSourceShapeChanged()` diffs the two to
    /// decide whether a deferred rebuild is owed once the session ends.
    private(set) var composedWithWearable = false
    private(set) var deviceBatteryLevel: Int?
    private(set) var deviceConnectionState: DeviceConnectionState?
    private(set) var deviceSetupFailure: String?
    /// Two independent pumps (connection-state, battery) rather than one task juggling both
    /// via `async let` — capturing `self` into an `async let`'s child task trips Swift 6's
    /// region-based "sending self risks causing data races" check even though every mutation
    /// is safely hopped back to MainActor; two top-level `Task { [weak self] in }`s (the same
    /// shape used everywhere else in this file) don't have that problem.
    private var deviceObservationTasks: [Task<Void, Never>] = []
    /// Dedup for the low-battery notification: fires once per drop below threshold, then
    /// re-arms once the level recovers with margin — avoids re-notifying on every reading
    /// while hovering right at the line.
    private var lowBatteryNotified = false
    // Default mirrors SegmentStore's own default root; overwritten with the real
    // `store.rootDirectory` during performSetUp once `store` exists.
    private var segmentRoot: URL = FileManager.default.urls(
        for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Sotto", isDirectory: true)
    /// Directory names (newest first) not yet consumed by history paging — populated fresh by
    /// `loadInitialHistory()`, drained 7-content-days-at-a-time by `loadNextHistoryPage()`.
    private var pendingHistoryDirectoryNames: [String] = []
    /// M9 unified home: chains `loadInitialHistory`/`loadMoreHistory`/`refreshLoadedHistory`
    /// against each other. `HomeScreen` fires `loadInitialHistory()` (a plain `.task`) and
    /// `refreshLoadedHistory()` (a `.task(id: pipeline.finalizedCount)`, which also runs on
    /// first appearance) concurrently at mount — without this chain their `await` points
    /// interleave and each can independently decide "today" isn't loaded yet and append its
    /// own copy, duplicating the section (caught via e2e screenshot review).
    private var historyTask: Task<Void, Never>?

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
        segmentRootOverride: URL? = nil,
        deviceStoreOverride: PairedDeviceStore? = nil,
        omiTransportOverride: (any OmiTransport)? = nil
    ) {
        self.installer = assetInstaller ?? SpeechAssetInstaller()
        self.networkMonitor = networkMonitor ?? WiFiMonitor()
        self.segmentRootOverride = segmentRootOverride
        self.deviceStoreOverride = deviceStoreOverride
        self.omiTransportOverride = omiTransportOverride
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
    /// Builds the new page into a local and swaps `historySections` only once it's ready —
    /// clearing it up front (the old behavior) blanked the list for the duration of the
    /// load, flashing the empty state on every relaunch and pull-to-refresh.
    func loadInitialHistory() async {
        let previous = historyTask
        let task = Task {
            await previous?.value
            pendingHistoryDirectoryNames = sortedHistoryDirectoryNames()
            let page = await nextHistoryPage()
            historySections = page
            hasLoadedHistoryOnce = true
        }
        historyTask = task
        await task.value
    }

    /// M9 unified home: appends the next 7-content-day page — a no-op once paging is
    /// exhausted (`hasMoreHistory == false`).
    func loadMoreHistory() async {
        let previous = historyTask
        let task = Task {
            await previous?.value
            guard hasMoreHistory else { return }
            let page = await nextHistoryPage()
            historySections.append(contentsOf: page)
        }
        historyTask = task
        await task.value
    }

    /// M9 unified home: re-reads `_day.json` for every already-loaded section (called where
    /// `refreshTodaySummary()` used to be — a finalize, delete, or scenePhase-active event),
    /// and prepends today's section if it now has content and isn't already loaded (a day
    /// with no folder yet at launch never entered the initial page).
    ///
    /// Only today is prepended; a non-loaded OLDER day gaining content retroactively
    /// (midnight-spanning finalize, rare) surfaces on the next pull-to-refresh or relaunch —
    /// accepted.
    func refreshLoadedHistory() async {
        let previous = historyTask
        let task = Task {
            await previous?.value
            var refreshed: [HistorySection] = []
            for section in historySections {
                // Content-filtered like `historySection(forDayName:)`: a day whose last
                // segment was just deleted must drop out here too, or its now-empty sticky
                // header keeps showing until the next full reload.
                guard let index = await loadDayIndex(dayDirectory: section.dayDirectory),
                      !index.segments.isEmpty || !index.gaps.isEmpty
                else { continue }
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
        historyTask = task
        await task.value
    }

    /// Drains `pendingHistoryDirectoryNames` from the front until either 7 content-days have
    /// been collected or the pending list is exhausted — empty/gap-less day folders are
    /// consumed from the list but contribute no section (SPEC: paging counts CONTENT days).
    /// Returns the page rather than mutating `historySections` itself — callers differ on
    /// whether the page replaces (initial load) or appends to (load-more) the current list.
    private func nextHistoryPage() async -> [HistorySection] {
        var page: [HistorySection] = []
        while !pendingHistoryDirectoryNames.isEmpty, page.count < 7 {
            let name = pendingHistoryDirectoryNames.removeFirst()
            if let section = await historySection(forDayName: name) {
                page.append(section)
            }
        }
        hasMoreHistory = !pendingHistoryDirectoryNames.isEmpty
        return page
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

    /// Lets the user clear the "Restored N transcripts from iCloud" line.
    func dismissRestoreStatus() {
        restoreStatus = nil
    }

    /// Applies a completed restore's result on the main actor: status line + full history
    /// reload (restore can add OLDER days the incremental refresh path won't surface).
    private func applyRestoreResult(_ count: Int) async {
        restoreStatus = "Restored \(count) transcript\(count == 1 ? "" : "s") from iCloud"
        await loadInitialHistory()
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
        // Delete-propagation: clean every backup sink's copy (design 2026-07-07 §3, delete verb).
        SyncSinkRegistry.remove(m4aURL: m4aURL, settings)
        await refreshLoadedHistory()
    }

    /// Rename-conversation spec (2026-07-07): Detail-view retitle. The .md is the source
    /// of truth — rewrite it first; if that fails (file gone, title sanitizes to empty)
    /// the index is never touched. Then the same choreography as `regenerateNotes`:
    /// index title, best-effort detached mirror export, history refresh. PreviewCache is
    /// NOT invalidated — previews derive from summary/transcript text, which a rename
    /// never changes.
    func renameSegment(m4aURL: URL, title: String, startTime: Date) async {
        let mdURL = m4aURL.deletingPathExtension().appendingPathExtension("md")
        guard ConversationMerger.applyTitle(to: mdURL, title: title, startTime: startTime)
        else { return }
        await dayIndex?.setTitle(m4aURL: m4aURL, title: title)
        // Rename rewrites the .md in place (filename unchanged) → a plain upsert (design §3).
        SyncSinkRegistry.upsert(m4aURL: m4aURL, settings)
        await refreshLoadedHistory()
    }

    /// Merge-conversations orchestration (spec 2026-07-06): file-level merge, then index
    /// update, queue/cache cleanup, best-effort mirror sync, history refresh, and
    /// best-effort notes regeneration. Returns false when the merge aborted — nothing on
    /// disk changed — so the UI can show an alert.
    func mergeSegments(dayDirectory: URL, entries: [DaySegmentEntry]) async -> Bool {
        guard let dayIndex else { return false }
        let outcome: ConversationMerger.Outcome
        do {
            outcome = try await ConversationMerger.merge(
                dayDirectory: dayDirectory, entries: entries)
        } catch {
            return false
        }
        await dayIndex.applyMerge(
            dayDirectory: dayDirectory, mergedEntry: outcome.mergedEntry,
            removedIDs: outcome.removedIDs)
        // Drop queue jobs for the removed parts AND the merged basename itself: the merged
        // entry's pre-merge job (if any) carries part 1's stale duration, which would poison
        // a later "Re-transcribe" with wrong frontmatter. With no job left,
        // `TranscriptionQueue.retranscribe` falls back to `parseStoreLayoutMetadata` — startDate
        // from the store-layout folder/basename, duration read from the actual stitched audio
        // via AVAudioFile — both correct for the merged file.
        for id in outcome.removedIDs + [outcome.mergedEntry.id] {
            await queue?.removeJob(m4aURL: dayDirectory.appendingPathComponent("\(id).m4a"))
        }
        for id in outcome.removedIDs + [outcome.mergedEntry.id] {
            PreviewCache.shared.invalidate(
                mdURL: dayDirectory.appendingPathComponent("\(id).md"))
        }
        // Merge = update the earliest part + drop the merged-away parts (design §3).
        SyncSinkRegistry.upsert(m4aURL: outcome.mergedM4AURL, settings)
        for id in outcome.removedIDs {
            SyncSinkRegistry.remove(m4aURL: dayDirectory.appendingPathComponent("\(id).m4a"), settings)
        }
        await refreshLoadedHistory()
        let mergedEntry = outcome.mergedEntry
        Task { await regenerateNotes(dayDirectory: dayDirectory, entry: mergedEntry) }
        return true
    }

    /// Best-effort notes regeneration for a just-merged conversation — M8 semantics
    /// exactly: any failure (Low Power Mode, model unavailable, transcript too short,
    /// generation error) leaves the merged file with its default heading; a merge is
    /// never failed by its notes. Mirrors the queue's postProcessorProvider gates.
    private func regenerateNotes(dayDirectory: URL, entry: DaySegmentEntry) async {
        guard !ProcessInfo.processInfo.isLowPowerModeEnabled,
              FoundationModelsPostProcessor.isModelAvailable else { return }
        let mdURL = dayDirectory.appendingPathComponent("\(entry.id).md")
        let m4aURL = dayDirectory.appendingPathComponent("\(entry.id).m4a")
        guard let file = TranscriptFile.parse(url: mdURL) else { return }
        // The processor only reads .text; segments/backend are structural placeholders.
        let input = TranscriptionResult(
            text: file.transcriptBody, segments: [], duration: entry.duration,
            backend: .speechAnalyzer)
        guard let notes = try? await FoundationModelsPostProcessor()
            .process(transcript: input, audio: nil) else { return }
        guard ConversationMerger.applyNotes(
            to: mdURL, notes: notes, startTime: entry.startTime) else { return }
        // Raw (unsanitized) title into the index — same divergence the transcription
        // transition handler accepts ("keep-stale by design" precedent).
        await dayIndex?.updateSegment(
            m4aURL: m4aURL, transcriptionState: "done", backend: nil, wordCount: nil,
            title: notes.title)
        PreviewCache.shared.invalidate(mdURL: mdURL)
        SyncSinkRegistry.upsert(m4aURL: m4aURL, settings)   // notes rewrite the .md → upsert
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

    /// Settings "Back up now": sweeps every local transcript into the iCloud container.
    /// Detached — container I/O must not ride the main actor. Container unavailable → 0.
    func backupAllToICloud() async -> Int {
        let root = segmentRoot
        return await Task.detached(priority: .utility) {
            await ICloudSyncSink().backupAll(localRoot: root)
        }.value
    }

    /// Settings "Restore from iCloud" (manual): additively hydrate local from the container,
    /// then reload history (restore can add OLDER day directories that the incremental refresh
    /// can't surface). Returns the number restored.
    func restoreFromICloud() async -> Int {
        guard let dayIndex else { return 0 }
        let root = segmentRoot
        let restored = await Task.detached(priority: .utility) {
            await ICloudRestore.run(localRoot: root, dayIndex: dayIndex)
        }.value
        if restored > 0 { await loadInitialHistory() }
        return restored
    }

    /// Settings "Remove iCloud backup": purge the whole Transcripts/ prefix. Local is untouched.
    func removeICloudBackup() async {
        await Task.detached(priority: .utility) { await ICloudSyncSink().removeAllBackups() }.value
    }

    /// Whether the container currently holds any transcript — gates the "Remove iCloud backup"
    /// action + informs the status line.
    func iCloudHasBackups() async -> Bool {
        await Task.detached(priority: .utility) { await ICloudSyncSink().hasBackups() }.value
    }

    /// Whether the ubiquity container resolves (signed in + entitled). Detached: resolution is
    /// documented as potentially slow and must not ride the main actor.
    func iCloudAvailable() async -> Bool {
        await Task.detached(priority: .utility) {
            FileManager.default.url(
                forUbiquityContainerIdentifier: ICloudSyncSink.containerIdentifier) != nil
        }.value
    }

    /// Settings "Back up now" (WebDAV): sweep every local transcript (+ audio when enabled)
    /// onto the configured server. Serialized behind pending event ops on the executor;
    /// bypasses the Wi-Fi gate (explicit user intent). Not configured → (0, 0).
    func backupAllToWebDAV() async -> (transcripts: Int, audio: Int) {
        guard let config = WebDAVConfig.load(settings: settings) else { return (0, 0) }
        return await WebDAVExecutor.shared.backupAll(localRoot: segmentRoot, config: config)
    }

    /// Settings "Restore from server": additive hydrate, then reload history — same
    /// reasoning as restoreFromICloud (restored days can predate the incremental refresh).
    /// Nil means the server couldn't be reached/listed at all; 0 means it was reached and
    /// had nothing new — the Settings view distinguishes the two in its copy.
    func restoreFromWebDAV() async -> Int? {
        guard let dayIndex, let config = WebDAVConfig.load(settings: settings) else { return nil }
        let restored = await WebDAVExecutor.shared.restore(
            localRoot: segmentRoot, config: config, dayIndex: dayIndex)
        if let n = restored, n > 0 { await loadInitialHistory() }
        return restored
    }

    /// Settings "Test connection": PROPFIND Depth 0 against the saved base URL.
    func testWebDAVConnection() async -> WebDAVTestResult {
        guard let config = WebDAVConfig.load(settings: settings) else {
            return .failed("not configured")
        }
        return await WebDAVExecutor.shared.testConnection(config: config)
    }

    /// The executor's last outcome, for the Settings status line.
    func webdavStatus() async -> WebDAVStatus {
        await WebDAVExecutor.shared.lastOutcome
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

        // Pre-release folder-picker teardown (design §8/§12): clear the dead M11 sync bookmark
        // keys so no dangling security-scoped bookmark lingers. Best-effort, no data migration
        // (there is no folder-picker install base).
        settings.defaults.removeObject(forKey: "syncDestinationBookmark")
        settings.defaults.removeObject(forKey: "syncDestinationDisplayName")

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
                    if settings.transcriptionEngine == .deepgram, keychain.get("deepgramAPIKey") != nil {
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
                        m4aURL: job.m4aURL, startTime: job.startDate, duration: job.duration,
                        source: job.source)
                }
            }

            await recorder.setSegmentHandler { segment in
                Task {
                    await dayIndexStore.recordQueuedSegment(
                        m4aURL: segment.m4aURL,
                        startTime: segment.startDate,
                        duration: segment.duration,
                        source: segment.source)
                    await transcriptionQueue.enqueue(segment)
                    await transcriptionQueue.drain()
                }
            }

            // M12: the recorder is long-lived — stored so a later pair/forget rebuild
            // (`rebuildPipelineIfIdle`) can reuse it via `composePipeline` instead of
            // reconstructing it (see that property's doc comment for why).
            self.recorder = recorder
            composePipeline(recorder: recorder)

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
                    // Backup fan-out: after retention has decided what stays, mirror the
                    // finalized transcript to every active sink (design 2026-07-07). AFTER
                    // retention on purpose — the backup reflects what the app keeps (the
                    // transcript always ships; iCloud ignores audio anyway). Sinks resolved
                    // fresh so a toggle applies immediately; each op detached + failure-isolated
                    // inside the registry, so provider I/O never blocks this handler.
                    if transition.job.state == .done {
                        SyncSinkRegistry.upsert(m4aURL: transition.job.m4aURL, settings)
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
            // M10 diagnostics for the reported "Deepgram toggle reset itself" mystery
            // (2026-07-05: observed on simulator relaunches; key survived, onboarding did
            // not reappear, so the defaults plist was NOT wiped). Logs the raw stored
            // values every launch so the next occurrence is checkable in Console.app
            // (subsystem com.decanlys.Sotto, category Settings) instead of unreproducible.
            Logger(subsystem: "com.decanlys.Sotto", category: "Settings").info(
                "launch engine=\(settings.transcriptionEngine.rawValue, privacy: .public) rawNew=\(settings.defaults.string(forKey: "transcriptionEngine") ?? "nil", privacy: .public) rawLegacy=\(String(describing: settings.defaults.object(forKey: "deepgramEnabled") ?? "nil"), privacy: .public) hasKey=\(keychain.get("deepgramAPIKey") != nil)")
            let hasDeepgramKey = settings.transcriptionEngine == .deepgram && keychain.get("deepgramAPIKey") != nil
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

            // iCloud restore (additive, idempotent): hydrate transcripts backed up from a
            // previous device into the local store, then rebuild affected day indexes so they
            // surface in history. Detached — container download can block for seconds. Bootstrap
            // safety: outbound deletes are event-driven only, so an empty local store never wipes
            // the backup before this fills it (design §5).
            if settings.iCloudBackupEnabled {
                Task.detached { [weak self] in
                    let restored = await ICloudRestore.run(
                        localRoot: store.rootDirectory, dayIndex: dayIndexStore)
                    guard restored > 0 else { return }
                    await self?.applyRestoreResult(restored)
                }
            }
        } catch {
            setupError = String(describing: error)
        }
    }

    /// M12: builds the audio source (the paired-Omi failover branch, or the plain phone
    /// mic), a fresh `ListeningPipeline`, and its `AudioSessionObserver` — reusing the
    /// passed-in LONG-LIVED `recorder` (and, through its already-installed segment handler,
    /// the day index + transcription queue wired up once in `performSetUp`) rather than
    /// reconstructing any of them.
    ///
    /// Called once from `performSetUp` and again from `rebuildPipelineIfIdle()` (pair/forget
    /// while idle). The split exists because re-running the REST of `performSetUp` on every
    /// pair/forget is not safe: it would construct a SECOND `TranscriptionQueue` (and
    /// `DayIndexStore`) against the same persisted `transcription-jobs.json`/`_day.json`
    /// files as the first — a job the original queue's own launch-drain `Task` is mid-way
    /// through transcribing would then race a brand-new queue instance reading/writing the
    /// same files — plus it would reload the CoreML VAD detector for no reason. Everything
    /// else `performSetUp` does (salvage sweep, heartbeat/gap recording, retention sweep,
    /// launch drain) is launch-only and must run exactly once per process.
    private func composePipeline(recorder: RecorderStateMachine) {
        for task in deviceObservationTasks { task.cancel() }
        deviceObservationTasks = []
        lowBatteryNotified = false
        deviceConnectionState = nil
        deviceBatteryLevel = nil
        deviceSetupFailure = nil

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

        let newPipeline = ListeningPipeline(
            source: source, recorder: recorder, heartbeat: HeartbeatStore(),
            liveActivity: SottoLiveActivityController(),
            notifications: UserNotificationScheduler())
        pipeline = newPipeline

        let sessionObserver = AudioSessionObserver(backgroundTasks: UIKitBackgroundTasks())
        // Non-nil only for the composed (Omi + phone mic) path — its authoritative, async
        // `activeSourceType` decides whether an AVAudioSession event is even relevant: while
        // the Omi (a BLE peripheral, not an AVAudioSession input route) is capturing, a phone
        // interruption/route-change/media-services-reset must NOT park a perfectly healthy
        // recording. `nil` on the plain phone-mic path ⇒ every guard below is skipped and
        // behavior is exactly what it was before M12.
        let switching = source as? FailoverAudioSource
        sessionObserver.onInterruptionBegan = { [weak newPipeline, weak switching] in
            if let switching, await switching.activeSourceType != .phoneMic { return }
            await newPipeline?.interrupt()
        }
        sessionObserver.onInterruptionEndedShouldResume = { [weak newPipeline, weak switching] shouldResume in
            if let switching, await switching.activeSourceType != .phoneMic { return }
            // Foregrounded + system says resume → restart. Backgrounded: engine.start()
            // fails (561145187); recovery stays with the intent/notification/app-open.
            guard shouldResume, UIApplication.shared.applicationState == .active else { return }
            await newPipeline?.resumeFromInterruption()
        }
        sessionObserver.onRouteChangeDeviceUnavailable = { [weak switching, weak plainPhoneMic, weak newPipeline] in
            do {
                if let switching {
                    // Forwards to the phone mic's tap rebuild only when it's the active
                    // source; a no-op when the Omi is active (see `handleRouteChange`).
                    try await switching.handleRouteChange()
                } else {
                    try await plainPhoneMic?.rebuildTap()
                }
            } catch {
                // No valid input route: park honestly instead of silently losing capture.
                await newPipeline?.interrupt()
            }
        }
        sessionObserver.onMediaServicesReset = { [weak newPipeline, weak switching] in
            if let switching, await switching.activeSourceType != .phoneMic { return }
            // Full teardown + rebuild (SPEC): park, then restart the whole stack.
            await newPipeline?.interrupt()
            // Backgrounded: engine.start() fails (561145187); recovery stays with the
            // intent/notification/app-open, and interrupt() already scheduled the fallback.
            guard UIApplication.shared.applicationState == .active else { return }
            await newPipeline?.resumeFromInterruption()
        }
        sessionObserver.startObserving()
        observer = sessionObserver

        // Battery + connection observation (Settings, Task 11): only meaningful when an Omi
        // is actually composed into the source. There is no BLE traffic — and so nothing for
        // these streams to carry — until the pipeline is actually `start()`-ed (that's what
        // makes `OmiAudioSource` connect the transport); status/battery are only ever live
        // DURING a session, not before one starts (M12 final review Critical #1 — corrects an
        // earlier, inaccurate version of this comment that claimed otherwise).
        //
        // `OmiAudioSource.stop()` (called on every session stop AND every park — including a
        // phone call interruption, via `ListeningPipeline.performHalt`) finishes both of these
        // streams. Without the re-subscribe loop below, the very first stop/interruption would
        // permanently kill status updates for the rest of the process: Settings would freeze,
        // the Bluetooth banner would go stale, and the low-battery notification would never
        // fire again. Each loop iteration re-subscribes once the previous stream ends, so the
        // NEXT session picks status back up; the short sleep only guards against a hot spin
        // while genuinely idle between sessions.
        if let wearableSource {
            let stateTask = Task { [weak self] in
                while !Task.isCancelled, self != nil {
                    for await state in await wearableSource.connectionStates() {
                        // setupFailureMessage becomes readable once the codec characteristic
                        // has been processed — refresh it alongside each state change.
                        let failure = await wearableSource.setupFailureMessage
                        await MainActor.run {
                            self?.deviceConnectionState = state
                            self?.deviceSetupFailure = failure
                        }
                    }
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
            let batteryTask = Task { [weak self] in
                while !Task.isCancelled, self != nil {
                    for await level in await wearableSource.batteryLevels() {
                        await MainActor.run { self?.applyDeviceBattery(level) }
                    }
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
            deviceObservationTasks = [stateTask, batteryTask]
        }
    }

    /// M12 Settings low-battery notification: fires once per drop below
    /// `WearableConstants.lowBatteryThresholdPercent`, re-arming only once the level recovers
    /// with a 10-point margin (avoids re-notifying on every reading while hovering at the
    /// line). AppModel holds no scheduler reference of its own (mirrors `performSetUp`,
    /// which also constructs `UserNotificationScheduler()` inline) — constructed fresh here.
    private func applyDeviceBattery(_ level: Int) {
        deviceBatteryLevel = level
        if level <= WearableConstants.lowBatteryThresholdPercent, !lowBatteryNotified {
            lowBatteryNotified = true
            // Battery readings only flow while a wearable is composed, so the kind is
            // always set here; skipping on nil beats inventing a family name.
            if let kind = pairedDeviceKind {
                Task {
                    await UserNotificationScheduler()
                        .scheduleLowBatteryNotification(deviceName: kind.displayName, level: level)
                }
            }
        }
        if level > WearableConstants.lowBatteryThresholdPercent + 10 { lowBatteryNotified = false }
    }

    /// Settings pairing (Task 11): the pair sheet owns its own scan transport
    /// lifecycle, this just hands out a fresh one for the requested device family.
    func makeScanTransport(for kind: DeviceKind) -> any DeviceScanning {
        switch kind {
        case .omi: CoreBluetoothOmiTransport()
        }
    }

    /// Settings pairing flow: persists the pairing, updates `pairedDeviceName` immediately (M12
    /// final review Important #2 — Settings must reflect the new pairing right away even
    /// mid-session; before this fix it only updated inside `composePipeline`, so pairing while
    /// listening left Settings showing the "unpaired" UI as if pairing had silently failed),
    /// then rebuilds the pipeline immediately if nothing is listening. If something IS
    /// listening, the new source composes once the session actually ends —
    /// `rebuildIfSourceShapeChanged()`, called from every place that can bring the pipeline
    /// back to idle — not on the next relaunch.
    func pairDevice(_ discovery: WearableDiscovery) async {
        (deviceStoreOverride ?? PairedDeviceStore()).pair(
            PairedDevice(id: discovery.id, name: discovery.name, kind: discovery.kind))
        pairedDeviceName = discovery.name
        pairedDeviceKind = discovery.kind
        await rebuildPipelineIfIdle()
    }

    /// Settings "Forget This Device" (Task 11). Name/battery/connection are cleared
    /// immediately regardless of whether a rebuild can happen right away — Settings must stop
    /// showing a device we've just told the user we'd stop tracking, even if the actual source
    /// swap has to wait for the current session to end (see `pairDevice` above for the same fix).
    func forgetDevice() async {
        (deviceStoreOverride ?? PairedDeviceStore()).forget()
        pairedDeviceName = nil
        pairedDeviceKind = nil
        deviceBatteryLevel = nil
        deviceConnectionState = nil
        await rebuildPipelineIfIdle()
    }

    /// Re-runs source composition + pipeline/observer wiring when nothing is listening
    /// (mirroring the Settings "changes apply after launch" convention otherwise). Reuses
    /// the long-lived `recorder` via `composePipeline` — see that method's doc comment for
    /// why re-running all of `performSetUp` here would be unsafe. Falls back to a full
    /// `ensureSetUp()` only when setup hasn't produced a `recorder` yet at all (there is
    /// nothing to reuse, so that IS the first run, not a re-run).
    private func rebuildPipelineIfIdle() async {
        guard pipeline?.status == .idle || pipeline == nil else { return }
        guard let recorder else {
            setupTask = nil
            await ensureSetUp()
            return
        }
        composePipeline(recorder: recorder)
    }

    /// Wraps every production path that stops a session (currently: the Home screen's Stop
    /// button) so a pair/forget that happened WHILE that session was running gets its deferred
    /// rebuild the moment the session actually ends (M12 final review Important #2), instead of
    /// silently waiting for the next app launch. `toggleFromIntent`'s "stop" case never applies
    /// here — a Live Activity/notification toggle only pauses (`pauseByUser`), it never fully
    /// stops, so it never needs this hook.
    func stopListening() async {
        await pipeline?.stop()
        await rebuildIfSourceShapeChanged()
    }

    /// Idle- and shape-gated: a no-op unless the pipeline is genuinely idle AND what's paired
    /// right now differs from what the CURRENT pipeline was actually composed with
    /// (`composedWithWearable`) — i.e. a pair/forget occurred while a session was in flight and
    /// hasn't been picked up yet. Deliberately simple: piggybacks on the existing
    /// `rebuildPipelineIfIdle`/`composePipeline` path rather than adding a second one.
    private func rebuildIfSourceShapeChanged() async {
        guard pipeline?.status == .idle else { return }
        let pairedNow = (deviceStoreOverride ?? PairedDeviceStore()).device != nil
        guard pairedNow != composedWithWearable else { return }
        await rebuildPipelineIfIdle()
    }
}

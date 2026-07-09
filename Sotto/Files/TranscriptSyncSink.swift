import Foundation

/// A destination that mirrors finalized transcripts out of the canonical local store. All
/// methods are best-effort and MUST NEVER throw into the caller: a slow/failed backup can
/// never fail a transcription job, block the queue, or ride the main actor.
///
/// The surface is `upsert`/`remove` only — permanently. No Sotto feature performs a
/// filesystem-level rename/move: merge reuses the earliest part's existing basename
/// (`upsert(earliest) + remove(others)`), and rename rewrites the `.md` content in place
/// without changing the filename (a plain `upsert`). So no `move` verb is ever needed.
protocol TranscriptSyncSink: Sendable {
    /// Mirror a finalized conversation. `markdown` is always present; `audio` is present only
    /// when retention kept it. Sinks that don't back up audio (iCloud) ignore it.
    func upsert(_ segment: SyncSegment) async
    /// Propagate a local deletion or a merge-consumed part.
    func remove(day: String, basename: String) async
}

/// One finalized conversation, as the fan-out sees it. `day`/`basename` are the store-layout
/// coordinates (`<root>/<day>/<basename>.{md,m4a}`).
struct SyncSegment: Sendable {
    let day: String        // "2026-07-07" (day-directory name)
    let basename: String   // "09-15-00"  (filename stem, shared by .md/.m4a)
    let markdown: URL      // local source .md
    let audio: URL?        // local source .m4a; nil when retention deleted it
}

extension SyncSegment {
    /// Derives the segment from a conversation's `.m4a` URL (`<root>/<day>/<basename>.m4a`).
    /// `audio` is included only when the file still exists — retention may have deleted it
    /// before the mirror runs, and the transcript must still ship.
    init(m4aURL: URL) {
        let day = m4aURL.deletingLastPathComponent().lastPathComponent
        let basename = m4aURL.deletingPathExtension().lastPathComponent
        let markdown = m4aURL.deletingPathExtension().appendingPathExtension("md")
        let audio = FileManager.default.fileExists(atPath: m4aURL.path) ? m4aURL : nil
        self.init(day: day, basename: basename, markdown: markdown, audio: audio)
    }
}

/// Assembles the active sinks from current settings and fans mutation events out to them.
/// Sinks are resolved FRESH per event (mirrors the existing per-job `serviceProvider`
/// pattern), so toggling a provider applies immediately with nothing to reconstruct.
enum SyncSinkRegistry {
    #if DEBUG
    /// Test seam: when non-nil, `activeSinks` returns this verbatim, letting a test inject a
    /// recording sink. Process-wide mutable state — tests that set it must be `.serialized`.
    nonisolated(unsafe) static var testSinks: [any TranscriptSyncSink]?
    #endif

    static func activeSinks(
        _ settings: SettingsStore, keychain: KeychainStore = KeychainStore()
    ) -> [any TranscriptSyncSink] {
        #if DEBUG
        if let testSinks { return testSinks }
        #endif
        var sinks: [any TranscriptSyncSink] = []
        if settings.iCloudBackupEnabled { sinks.append(ICloudSyncSink()) }
        if settings.webdavEnabled, let config = WebDAVConfig.load(settings: settings, keychain: keychain) {
            sinks.append(WebDAVSyncSink(config: config, wifiOnly: settings.wifiOnlyUpload))
        }
        // Later phases append here: GoogleDriveSyncSink(...)
        return sinks
    }

    /// Fan a finalized-conversation upsert out to every active sink — each detached and
    /// failure-isolated so no sink's slow/failed I/O rides the caller. Safe to call from the
    /// MainActor choke points AND the @Sendable transition closure: takes a Sendable
    /// `SettingsStore` and captures no actor state.
    static func upsert(m4aURL: URL, _ settings: SettingsStore) {
        let segment = SyncSegment(m4aURL: m4aURL)
        for sink in activeSinks(settings) {
            Task.detached(priority: .utility) { await sink.upsert(segment) }
        }
    }

    /// Fan a deletion/merge-consumed-part out to every active sink, detached + failure-isolated.
    static func remove(m4aURL: URL, _ settings: SettingsStore) {
        let day = m4aURL.deletingLastPathComponent().lastPathComponent
        let basename = m4aURL.deletingPathExtension().lastPathComponent
        for sink in activeSinks(settings) {
            Task.detached(priority: .utility) { await sink.remove(day: day, basename: basename) }
        }
    }
}

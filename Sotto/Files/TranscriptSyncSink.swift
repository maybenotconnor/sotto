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

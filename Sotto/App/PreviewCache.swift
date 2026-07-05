import Foundation

/// M9: infinite-scroll history makes row previews (`TranscriptFile.previewText`) hot — every
/// visible row would otherwise re-read and re-parse its `.md` file on each render. Cached by
/// mtime rather than time-based expiry: a `.md` only ever changes when re-transcribed/edited,
/// and the file's modification date is the one signal that's always correct for that.
@MainActor
final class PreviewCache {
    static let shared = PreviewCache()

    private var entries: [String: (mtime: Date, preview: String)] = [:]

    /// `TranscriptFile.previewText` for the md at `mdURL`, cached and invalidated by
    /// modification date. Nil when the file is missing/unreadable (evicts any stale entry).
    func preview(for mdURL: URL) -> String? {
        let key = mdURL.path
        guard let mtime = modificationDate(of: mdURL) else {
            entries.removeValue(forKey: key)
            return nil
        }
        if let cached = entries[key], cached.mtime == mtime {
            return cached.preview
        }
        guard let file = TranscriptFile.parse(url: mdURL) else {
            entries.removeValue(forKey: key)
            return nil
        }
        let preview = file.previewText
        entries[key] = (mtime: mtime, preview: preview)
        return preview
    }

    /// Forces the next `preview(for:)` lookup for this file to re-parse, regardless of
    /// mtime — used after a caller rewrites a `.md` in place within the same tick a
    /// filesystem mtime granularity might not distinguish.
    func invalidate(mdURL: URL) {
        entries.removeValue(forKey: mdURL.path)
    }

    /// `FileManager.attributesOfItem` rather than `URL.resourceValues` — the latter caches
    /// values on the URL value across calls (a stale-vs-fresh comparison would then always
    /// see its own cached mtime), while `attributesOfItem` re-stats the file every call.
    private func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}

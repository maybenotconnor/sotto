import Foundation

/// M11 cloud sync: persists the user-picked export folder as a security-scoped bookmark.
/// Bookmarks — not raw paths — because iOS file-provider URLs (iCloud Drive, Google Drive,
/// OpenCloud, …) are only re-openable across launches via bookmark resolution.
struct SyncDestinationStore: Sendable {
    // UserDefaults isn't marked Sendable on this SDK, but it is documented as internally
    // thread-safe — nonisolated(unsafe) matches the SettingsStore precedent.
    nonisolated(unsafe) let defaults: UserDefaults
    static let bookmarkKey = "syncDestinationBookmark"
    static let displayNameKey = "syncDestinationDisplayName"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isConfigured: Bool { defaults.data(forKey: Self.bookmarkKey) != nil }

    var displayName: String? { defaults.string(forKey: Self.displayNameKey) }

    /// `url` comes from `.fileImporter` (already security-scope-granted). The access
    /// start/stop pair is required for bookmark creation on provider-backed URLs; a `false`
    /// start (plain file URLs, e.g. in tests) is fine — creation still works for those.
    func save(url: URL) throws {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        let bookmark = try url.bookmarkData()
        defaults.set(bookmark, forKey: Self.bookmarkKey)
        defaults.set(url.lastPathComponent, forKey: Self.displayNameKey)
    }

    func clear() {
        defaults.removeObject(forKey: Self.bookmarkKey)
        defaults.removeObject(forKey: Self.displayNameKey)
    }

    /// Resolves the stored bookmark. Stale bookmarks (provider moved the folder) are
    /// refreshed in place per Apple's documented contract. Returns nil when unset or the
    /// folder is gone/unreachable — callers treat that as "sync off for now", never an error.
    func resolve() -> URL? {
        guard let data = defaults.data(forKey: Self.bookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale) else { return nil }
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        if stale, let refreshed = try? url.bookmarkData() {
            defaults.set(refreshed, forKey: Self.bookmarkKey)
        }
        return url
    }
}

/// M11 cloud sync: best-effort mirror of finalized conversations into the sync destination,
/// preserving the local store layout — `<destination>/<yyyy-MM-dd>/<HH-mm-ss>.md` plus the
/// `.m4a` when it still exists (export runs AFTER retention, so the cloud mirrors what the
/// app actually keeps; the transcript always ships). Every write goes through
/// NSFileCoordinator — file-provider backends require coordinated access for correctness.
/// All failures degrade to "didn't copy" (reflected in the return value + best-effort
/// retry via the next export/exportAll); nothing here ever throws into a caller.
enum SegmentExporter {
    struct Exported: Equatable {
        let markdown: Bool
        let audio: Bool
    }

    @discardableResult
    static func export(m4aURL: URL, to destination: URL) -> Exported {
        let didAccess = destination.startAccessingSecurityScopedResource()
        defer { if didAccess { destination.stopAccessingSecurityScopedResource() } }
        let dayName = m4aURL.deletingLastPathComponent().lastPathComponent
        let dayDir = destination.appendingPathComponent(dayName, isDirectory: true)
        let mdURL = m4aURL.deletingPathExtension().appendingPathExtension("md")

        var markdown = false
        var audio = false
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        coordinator.coordinate(writingItemAt: dayDir, options: [], error: &coordinationError) { dir in
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            markdown = copyReplacing(from: mdURL, into: dir)
            audio = copyReplacing(from: m4aURL, into: dir)
        }
        return Exported(markdown: markdown, audio: audio)
    }

    /// Settings "Export all now" backfill: mirrors every `.md`/`.m4a` under `root`'s day
    /// directories. `_day.json` (internal index) and `.caf` (pre-transcode scratch) never
    /// leave the device. Returns the number of files copied.
    @discardableResult
    static func exportAll(root: URL, to destination: URL) -> Int {
        let didAccess = destination.startAccessingSecurityScopedResource()
        defer { if didAccess { destination.stopAccessingSecurityScopedResource() } }
        guard let days = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return 0 }

        var copied = 0
        let coordinator = NSFileCoordinator()
        for day in days {
            guard (try? day.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  let files = try? FileManager.default.contentsOfDirectory(
                      at: day, includingPropertiesForKeys: nil) else { continue }
            let exportable = files.filter { ["md", "m4a"].contains($0.pathExtension) }
            guard !exportable.isEmpty else { continue }
            let targetDay = destination.appendingPathComponent(day.lastPathComponent, isDirectory: true)
            var coordinationError: NSError?
            coordinator.coordinate(writingItemAt: targetDay, options: [], error: &coordinationError) { dir in
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                for file in exportable where copyReplacing(from: file, into: dir) {
                    copied += 1
                }
            }
        }
        return copied
    }

    private static func copyReplacing(from source: URL, into directory: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: source.path) else { return false }
        let target = directory.appendingPathComponent(source.lastPathComponent)
        do {
            if FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.removeItem(at: target)
            }
            try FileManager.default.copyItem(at: source, to: target)
            return true
        } catch {
            return false
        }
    }
}

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
        guard let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        if stale, let refreshed = try? url.bookmarkData() {
            defaults.set(refreshed, forKey: Self.bookmarkKey)
        }
        return url
    }
}

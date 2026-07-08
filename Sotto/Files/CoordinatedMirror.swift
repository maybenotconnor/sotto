import Foundation

/// Coordinated (NSFileCoordinator) file mirroring into a destination root that preserves the
/// `<root>/<day>/<file>` day-directory layout. Extracted from the deleted M11 `SegmentExporter`;
/// the security-scoped-bookmark handling went with the folder picker — a ubiquity container is
/// app-owned and needs no access scoping. Best-effort: every failure degrades to "didn't
/// mirror"; nothing here ever throws into a caller.
enum CoordinatedMirror {
    /// Coordinated copy of `source` into `<root>/<day>/`, creating the day directory and
    /// replacing any existing file of the same name. Returns true when the file landed;
    /// false when the source is missing or the copy failed.
    @discardableResult
    static func copy(_ source: URL, day: String, into root: URL) -> Bool {
        let dayDir = root.appendingPathComponent(day, isDirectory: true)
        var copied = false
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        coordinator.coordinate(writingItemAt: dayDir, options: [], error: &coordinationError) { dir in
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            copied = copyReplacing(from: source, into: dir)
        }
        return copied
    }

    /// Coordinated removal of `<root>/<day>/<name>` for each name. Missing files are fine
    /// (never mirrored, or already gone) — local state is truth.
    static func remove(_ names: [String], day: String, from root: URL) {
        let dayDir = root.appendingPathComponent(day, isDirectory: true)
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        coordinator.coordinate(writingItemAt: dayDir, options: [], error: &coordinationError) { dir in
            for name in names {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
            }
        }
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

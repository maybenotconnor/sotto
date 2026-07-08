import Foundation

/// iCloud transcript backup (design 2026-07-07): mirrors finalized `.md` transcripts — never
/// audio — into the app's private ubiquity container under a `Transcripts/` prefix. The
/// container is NOT document-scope-public, so the backup never appears in Files.app and can't
/// be confused with the canonical local store.
///
/// Best-effort and failure-isolated per `TranscriptSyncSink`: signed out / iCloud unavailable
/// → the resolver returns nil and every op is a silent no-op (the "sync off for now, never an
/// error" degrade). Retried implicitly by the next event or a manual "Back up now".
struct ICloudSyncSink: TranscriptSyncSink {
    static let containerIdentifier = "iCloud.com.decanlys.Sotto"

    /// Resolves `<container>` (NOT yet `Transcripts/`), or nil when iCloud is unavailable.
    /// Injected so tests can supply a temp dir or force the unavailable path (`{ nil }`).
    /// `url(forUbiquityContainerIdentifier:)` is documented as potentially slow — this closure
    /// is only ever CALLED from the async ops below (which the registry runs detached), never
    /// from `init`/`activeSinks` on the calling actor.
    private let resolveContainer: @Sendable () -> URL?

    init(resolveContainer: @Sendable @escaping () -> URL? = {
        FileManager.default.url(forUbiquityContainerIdentifier: ICloudSyncSink.containerIdentifier)
    }) {
        self.resolveContainer = resolveContainer
    }

    private func transcriptsRoot() -> URL? {
        resolveContainer()?.appendingPathComponent("Transcripts", isDirectory: true)
    }

    // MARK: TranscriptSyncSink

    func upsert(_ segment: SyncSegment) async {
        guard let root = transcriptsRoot() else { return }   // signed out → no-op
        CoordinatedMirror.copy(segment.markdown, day: segment.day, into: root)   // .md only; audio ignored
    }

    func remove(day: String, basename: String) async {
        guard let root = transcriptsRoot() else { return }
        CoordinatedMirror.remove(["\(basename).md"], day: day, from: root)
    }

    // MARK: Backfill / purge (Settings "Back up now" / "Remove iCloud backup")

    /// Sweeps every `<localRoot>/<day>/*.md` into the container, skipping `_day.json`/`.caf`/
    /// `.m4a`. Returns the number of transcripts copied. Container nil → 0.
    func backupAll(localRoot: URL) async -> Int {
        guard let root = transcriptsRoot() else { return 0 }
        guard let days = try? FileManager.default.contentsOfDirectory(
            at: localRoot, includingPropertiesForKeys: [.isDirectoryKey]) else { return 0 }
        var copied = 0
        for day in days {
            guard (try? day.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  let files = try? FileManager.default.contentsOfDirectory(
                      at: day, includingPropertiesForKeys: nil) else { continue }
            for md in files where md.pathExtension == "md" {
                if CoordinatedMirror.copy(md, day: day.lastPathComponent, into: root) { copied += 1 }
            }
        }
        return copied
    }

    /// Coordinated removal of the entire `Transcripts/` prefix — for the user who wants their
    /// transcripts GONE from iCloud, not just paused. Container nil → no-op.
    func removeAllBackups() async {
        guard let root = transcriptsRoot() else { return }
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        coordinator.coordinate(writingItemAt: root, options: .forDeleting, error: &coordinationError) { dir in
            try? FileManager.default.removeItem(at: dir)
        }
    }

    /// Whether the container currently holds any transcript — drives showing the "Remove iCloud
    /// backup" action. Container nil → false.
    func hasBackups() async -> Bool {
        guard let root = transcriptsRoot() else { return false }
        guard let days = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return false }
        for day in days {
            guard (try? day.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  let files = try? FileManager.default.contentsOfDirectory(
                      at: day, includingPropertiesForKeys: nil) else { continue }
            for md in files where md.pathExtension == "md" { return true }
        }
        return false
    }
}

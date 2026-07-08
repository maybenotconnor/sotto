import Foundation

/// iCloud restore (design 2026-07-07): the half that saves the user on a new phone. Copies
/// every container transcript missing locally into `Documents/Sotto`, then rebuilds the
/// affected `_day.json` so restored conversations appear in history.
///
/// Additive + idempotent: never overwrites an existing local `.md` (local is canonical), and
/// re-running restores only what's still missing. Bootstrap safety: because outbound deletes
/// are event-driven only, an empty local store emits zero deletes — a fresh install can never
/// wipe the backup before restoring from it.
enum ICloudRestore {
    /// Returns the number of transcripts copied in. `containerRoot` nil resolves the real
    /// ubiquity container; tests inject a temp dir.
    static func run(localRoot: URL, containerRoot: URL? = nil, dayIndex: DayIndexStore) async -> Int {
        let container = containerRoot ?? FileManager.default
            .url(forUbiquityContainerIdentifier: ICloudSyncSink.containerIdentifier)
        guard let transcripts = container?.appendingPathComponent("Transcripts", isDirectory: true),
              let dayDirs = try? FileManager.default.contentsOfDirectory(
                  at: transcripts, includingPropertiesForKeys: [.isDirectoryKey]) else { return 0 }

        var restored = 0
        var touchedDays: Set<String> = []
        for dayDir in dayDirs {
            guard (try? dayDir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            else { continue }
            let day = dayDir.lastPathComponent
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: dayDir, includingPropertiesForKeys: nil) else { continue }

            for md in files where md.pathExtension == "md" {
                // Evicted placeholder on a fresh device: request download; the coordinated read
                // below then blocks until it materializes. `try?` — a non-ubiquitous URL (tests,
                // already-local) simply isn't downloadable, which is fine.
                try? FileManager.default.startDownloadingUbiquitousItem(at: md)

                let localDay = localRoot.appendingPathComponent(day, isDirectory: true)
                let localMD = localDay.appendingPathComponent(md.lastPathComponent)
                guard !FileManager.default.fileExists(atPath: localMD.path) else { continue }  // never overwrite

                try? FileManager.default.createDirectory(
                    at: localDay, withIntermediateDirectories: true)
                var copied = false
                let coordinator = NSFileCoordinator()
                var coordinationError: NSError?
                coordinator.coordinate(readingItemAt: md, options: [], error: &coordinationError) { src in
                    copied = (try? FileManager.default.copyItem(at: src, to: localMD)) != nil
                }
                if copied { restored += 1; touchedDays.insert(day) }
            }
        }

        // Rebuild _day.json from the restored .md frontmatter so history shows them. Restored
        // conversations have hasAudio = false — the rebuilder infers it from the (absent) .m4a.
        for day in touchedDays {
            _ = await dayIndex.rebuildAndPersist(
                dayDirectory: localRoot.appendingPathComponent(day, isDirectory: true))
        }
        return restored
    }
}

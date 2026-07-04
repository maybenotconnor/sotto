import Foundation

struct SegmentPaths: Sendable, Equatable {
    let cafURL: URL
    let m4aURL: URL
}

/// Segment file placement per SPEC "File output": `Documents/Sotto/<yyyy-MM-dd>/` where the
/// folder is the LOCAL date the segment STARTED; files are named `HH-mm-ss`. M5 adds .md
/// transcripts, `_day.json`, retention, and backup flags on top of this layout.
struct SegmentStore: Sendable {
    let rootDirectory: URL

    init(rootDirectory: URL? = nil) {
        self.rootDirectory = rootDirectory
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Sotto", isDirectory: true)
    }

    func pathsForSegment(startingAt date: Date) throws -> SegmentPaths {
        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "yyyy-MM-dd"
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH-mm-ss"

        let dayDirectory = rootDirectory.appendingPathComponent(
            dayFormatter.string(from: date), isDirectory: true)
        try FileManager.default.createDirectory(at: dayDirectory, withIntermediateDirectories: true)

        let base = timeFormatter.string(from: date)
        var name = base
        var suffix = 2
        while FileManager.default.fileExists(
            atPath: dayDirectory.appendingPathComponent("\(name).caf").path)
            || FileManager.default.fileExists(
                atPath: dayDirectory.appendingPathComponent("\(name).m4a").path)
        {
            name = "\(base)-\(suffix)"
            suffix += 1
        }
        return SegmentPaths(
            cafURL: dayDirectory.appendingPathComponent("\(name).caf"),
            m4aURL: dayDirectory.appendingPathComponent("\(name).m4a"))
    }

    func freeDiskBytes() -> Int64 {
        // Root may not exist yet; capacity is a volume property, so ask the parent.
        let probe = FileManager.default.fileExists(atPath: rootDirectory.path)
            ? rootDirectory
            : rootDirectory.deletingLastPathComponent()
        let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    func orphanedCAFs() -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: rootDirectory, includingPropertiesForKeys: nil) else { return [] }
        return enumerator.compactMap { item in
            guard let url = item as? URL, url.pathExtension == "caf" else { return nil }
            return url
        }
    }
}

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

    // Pinned per QA1480: unpinned formatters follow the device's calendar/locale, which can
    // produce Buddhist-era years or non-ASCII digits in what must be a literal ASCII layout.
    // TimeZone stays LOCAL on purpose — the spec files segments under the local date.
    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH-mm-ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        return formatter
    }()

    init(rootDirectory: URL? = nil) {
        self.rootDirectory = rootDirectory
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Sotto", isDirectory: true)
    }

    func pathsForSegment(startingAt date: Date) throws -> SegmentPaths {
        let dayDirectory = rootDirectory.appendingPathComponent(
            Self.dayFormatter.string(from: date), isDirectory: true)
        try FileManager.default.createDirectory(at: dayDirectory, withIntermediateDirectories: true)

        let base = Self.timeFormatter.string(from: date)
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

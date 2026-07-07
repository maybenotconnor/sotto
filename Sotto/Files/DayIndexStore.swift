import Foundation

/// Owner of `_day.json` (SPEC "File output"): written atomically after every segment and
/// state change; rebuildable from .md frontmatter (DayIndexRebuilder). Actor-serialized so
/// concurrent segment/transition events can't interleave read-modify-write cycles.
actor DayIndexStore {
    private let rootDirectory: URL

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        return formatter
    }()

    /// SPEC "File output": `_day.json` dates are ISO8601 strings with local offset
    /// (e.g. "2026-03-14T09:15:30-04:00"), not raw epoch numbers — the Documents tree
    /// is user-exposed (Files/Obsidian).
    // ISO8601DateFormatter (unlike DateFormatter) isn't Sendable; `nonisolated(unsafe)` is safe
    // here because the formatter is configured once at construction and only ever read (via
    // `.string(from:)`/`.date(from:)`) afterward — no concurrent mutation occurs.
    nonisolated(unsafe) private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = .current   // local offset per SPEC's example (Z when zone is UTC)
        return formatter
    }()

    init(rootDirectory: URL? = nil) {
        self.rootDirectory = rootDirectory
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Sotto", isDirectory: true)
    }

    func recordQueuedSegment(
        m4aURL: URL, startTime: Date, duration: TimeInterval,
        source: AudioSourceType = .phoneMic
    ) {
        let dayDirectory = m4aURL.deletingLastPathComponent()
        // A corrupt `_day.json` (Documents is user-editable) must not silently discard the
        // day's earlier segments — rebuild from disk (a fresh/empty folder rebuilds empty,
        // so this is strictly better than falling back to `empty(for:)`).
        var index = load(dayDirectory) ?? DayIndexRebuilder.rebuild(dayDirectory: dayDirectory)
        let entry = DaySegmentEntry(
            id: m4aURL.deletingPathExtension().lastPathComponent,
            startTime: startTime, duration: duration, backend: nil,
            hasAudio: true, wordCount: nil, transcriptionState: "queued",
            source: source == .phoneMic ? nil : source.rawValue)
        index.segments.removeAll { $0.id == entry.id }
        index.segments.append(entry)
        index.segments.sort { ($0.startTime, $0.id) < ($1.startTime, $1.id) }
        write(index, to: dayDirectory)
    }

    func updateSegment(
        m4aURL: URL, transcriptionState: String, backend: String?, wordCount: Int?,
        title: String? = nil
    ) {
        mutateEntry(for: m4aURL) { entry in
            entry.transcriptionState = transcriptionState
            if let backend { entry.backend = backend }
            if let wordCount { entry.wordCount = wordCount }
            if let title { entry.title = title }
        }
    }

    func setAudioRemoved(m4aURL: URL) {
        mutateEntry(for: m4aURL) { $0.hasAudio = false }
    }

    /// Rename-conversation spec (2026-07-07): Detail-view retitle — title only; the
    /// caller has already rewritten the .md (the source of truth) via `applyTitle`.
    func setTitle(m4aURL: URL, title: String) {
        mutateEntry(for: m4aURL) { $0.title = title }
    }

    /// Row-level deletion (List swipe-delete / Detail delete): unlike `setAudioRemoved`
    /// (retention: keeps the transcript, just marks audio gone), this drops the entry
    /// outright — the caller has removed both the .m4a and .md for this segment.
    func removeSegment(m4aURL: URL) {
        let dayDirectory = m4aURL.deletingLastPathComponent()
        guard var index = load(dayDirectory) else { return }
        let id = m4aURL.deletingPathExtension().lastPathComponent
        index.segments.removeAll { $0.id == id }
        write(index, to: dayDirectory)
    }

    /// Merge-conversations step 5: replaces the merged-away part entries with the single
    /// merged entry. Same corrupt-index rebuild fallback as `recordQueuedSegment` — and
    /// safe here for the same reason plus one more: by the time this runs the .md files
    /// already reflect the merged state, so a rebuild converges on what this write
    /// produces anyway (the spec's crash-safety story).
    func applyMerge(dayDirectory: URL, mergedEntry: DaySegmentEntry, removedIDs: [String]) {
        var index = load(dayDirectory) ?? DayIndexRebuilder.rebuild(dayDirectory: dayDirectory)
        let dropped = Set(removedIDs + [mergedEntry.id])
        index.segments.removeAll { dropped.contains($0.id) }
        index.segments.append(mergedEntry)
        index.segments.sort { ($0.startTime, $0.id) < ($1.startTime, $1.id) }
        write(index, to: dayDirectory)
    }

    func recordGap(onDayOf date: Date, from: Date, reason: String) {
        let dayDirectory = rootDirectory.appendingPathComponent(
            Self.dayFormatter.string(from: date), isDirectory: true)
        // Same corrupt-index rebuild fallback as recordQueuedSegment above.
        var index = load(dayDirectory) ?? DayIndexRebuilder.rebuild(dayDirectory: dayDirectory)
        index.gaps.append(DayGapEntry(from: from, reason: reason))
        index.gaps.sort { $0.from < $1.from }
        write(index, to: dayDirectory)
    }

    func index(forDay dayDirectory: URL) -> DayIndex? {
        load(dayDirectory)
    }

    /// M6's list view calls this when a day folder has files but no readable index
    /// (SPEC: the index is rebuildable). Rebuilds from disk and persists atomically.
    func rebuildAndPersist(dayDirectory: URL) -> DayIndex {
        let rebuilt = DayIndexRebuilder.rebuild(dayDirectory: dayDirectory)
        write(rebuilt, to: dayDirectory)
        return rebuilt
    }

    // MARK: - Private

    private func mutateEntry(for m4aURL: URL, _ mutate: (inout DaySegmentEntry) -> Void) {
        let dayDirectory = m4aURL.deletingLastPathComponent()
        guard var index = load(dayDirectory) else { return }
        let id = m4aURL.deletingPathExtension().lastPathComponent
        guard let position = index.segments.firstIndex(where: { $0.id == id }) else { return }
        mutate(&index.segments[position])
        write(index, to: dayDirectory)
    }

    private func load(_ dayDirectory: URL) -> DayIndex? {
        guard let data = try? Data(contentsOf: dayDirectory.appendingPathComponent("_day.json"))
        else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { dec in
            let container = try dec.singleValueContainer()
            if let string = try? container.decode(String.self),
               let date = Self.isoFormatter.date(from: string) {
                return date
            }
            // Tolerate pre-fix files that were written with the raw-epoch default strategy.
            let epoch = try container.decode(Double.self)
            return Date(timeIntervalSinceReferenceDate: epoch)
        }
        return try? decoder.decode(DayIndex.self, from: data)
    }

    private func write(_ index: DayIndex, to dayDirectory: URL) {
        try? FileManager.default.createDirectory(at: dayDirectory, withIntermediateDirectories: true)
        let url = dayDirectory.appendingPathComponent("_day.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, enc in
            var container = enc.singleValueContainer()
            try container.encode(Self.isoFormatter.string(from: date))
        }
        guard let data = try? encoder.encode(index) else { return }
        try? data.write(to: url, options: .atomic)   // temp file + rename per SPEC
        // Between the atomic rename above and setAttributes below, the file briefly exists
        // at the default (non-completeUntilFirstUserAuthentication) protection class. Writes
        // only ever happen while the app is foregrounded and running, so this window is
        // accepted rather than closed.
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path)
    }
}

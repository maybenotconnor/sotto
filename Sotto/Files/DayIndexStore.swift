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

    init(rootDirectory: URL? = nil) {
        self.rootDirectory = rootDirectory
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Sotto", isDirectory: true)
    }

    func recordQueuedSegment(m4aURL: URL, startTime: Date, duration: TimeInterval) {
        let dayDirectory = m4aURL.deletingLastPathComponent()
        var index = load(dayDirectory) ?? empty(for: dayDirectory)
        let entry = DaySegmentEntry(
            id: m4aURL.deletingPathExtension().lastPathComponent,
            startTime: startTime, duration: duration, backend: nil,
            hasAudio: true, wordCount: nil, transcriptionState: "queued")
        index.segments.removeAll { $0.id == entry.id }
        index.segments.append(entry)
        index.segments.sort { $0.startTime < $1.startTime }
        write(index, to: dayDirectory)
    }

    func updateSegment(m4aURL: URL, transcriptionState: String, backend: String?, wordCount: Int?) {
        mutateEntry(for: m4aURL) { entry in
            entry.transcriptionState = transcriptionState
            if let backend { entry.backend = backend }
            if let wordCount { entry.wordCount = wordCount }
        }
    }

    func setAudioRemoved(m4aURL: URL) {
        mutateEntry(for: m4aURL) { $0.hasAudio = false }
    }

    func recordGap(onDayOf date: Date, from: Date, reason: String) {
        let dayDirectory = rootDirectory.appendingPathComponent(
            Self.dayFormatter.string(from: date), isDirectory: true)
        var index = load(dayDirectory) ?? empty(for: dayDirectory)
        index.gaps.append(DayGapEntry(from: from, reason: reason))
        index.gaps.sort { $0.from < $1.from }
        write(index, to: dayDirectory)
    }

    func index(forDay dayDirectory: URL) -> DayIndex? {
        load(dayDirectory)
    }

    // MARK: - Private

    private func empty(for dayDirectory: URL) -> DayIndex {
        DayIndex(date: dayDirectory.lastPathComponent, segments: [], gaps: [])
    }

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
        return try? JSONDecoder().decode(DayIndex.self, from: data)
    }

    private func write(_ index: DayIndex, to dayDirectory: URL) {
        try? FileManager.default.createDirectory(at: dayDirectory, withIntermediateDirectories: true)
        let url = dayDirectory.appendingPathComponent("_day.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(index) else { return }
        try? data.write(to: url, options: .atomic)   // temp file + rename per SPEC
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path)
    }
}

# M5 — File Store: `_day.json` Index, Retention, Gaps, Backup Flags Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement spec milestone M5: the atomic, rebuildable `_day.json` day index (segments + gaps), audio retention policy (default delete-after-transcription), iCloud-backup exclusions for audio, and the M4 carryovers (relative-path `jobs.json`, queue job-transition signal, salvage gap entries).

**Architecture:** A `DayIndexStore` actor owns `_day.json` per day folder (atomic temp+rename writes, sorted by startTime, rebuildable by scanning `.md` frontmatter). The `TranscriptionQueue` gains a job-transition handler (done/failed, carrying the `TranscriptionResult` for word counts) and persists Documents-relative paths (tolerating the old absolute format). Retention is a pure enforcement layer driven from AppModel's transition handler plus a launch sweep. Backup exclusion joins Data Protection in `transcodeToM4A` (single owner for every produced m4a).

**Tech Stack:** Foundation only (JSON, FileManager, URLResourceValues), Swift 6 strict concurrency, Swift Testing.

## Global Constraints

- Test command: `xcodebuild test -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone Air' 2>&1 | tail -5` → `** TEST SUCCEEDED **` (slow; Busy → `xcrun simctl shutdown all`, retry). New files → `xcodegen generate`. Zero Swift warnings (appintents exempt). Swift 6, `SWIFT_DEFAULT_ACTOR_ISOLATION: nonisolated`.
- Spec bindings (docs/SPEC.md "File output"): `_day.json` written **atomically (temp file + rename) after every segment** and **rebuildable by scanning the folder's .md frontmatter**; folder = LOCAL date segment started; `transcriptionState`: `queued | done | failed`; gaps `{from, reason}` with reason `uncleanShutdown`; **.md transcripts + _day.json included in backup; .m4a marked `isExcludedFromBackup`**; retention default **delete after transcription** (others: keep 7 days / keep forever), transcripts keep forever.
- Segment `id` = the file basename (e.g. `09-15-30`), matching spec's example.
- Existing contracts survive: queue drain semantics incl. environmental-error classification (a `.blocked` outcome fires NO transition); salvage-before-queue ordering; all pipeline invariants.
- Commits end with:

  Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>

## File Structure

```
Sotto/Files/DayIndex.swift            ← DayIndex/DaySegmentEntry/DayGapEntry models
Sotto/Files/DayIndexStore.swift       ← actor: record/update/gap/load/atomic write
Sotto/Files/DayIndexRebuilder.swift   ← .md frontmatter scan → DayIndex
Sotto/Files/RetentionPolicy.swift     ← AudioRetention, SettingsStore, RetentionEnforcer
Sotto/Transcription/TranscriptionQueue.swift ← transition handler + relative-path persistence (modify)
Sotto/Segments/CAFSegmentWriter.swift ← isExcludedFromBackup on produced m4a (modify)
Sotto/App/AppModel.swift              ← wiring (modify)
SottoTests/DayIndexTests.swift, RetentionTests.swift (new); TranscriptionQueueTests.swift,
RecorderIntegrationTests.swift, Fakes.swift (modify)
```

---

### Task 1: DayIndex models + DayIndexStore actor

**Files:**
- Create: `Sotto/Files/DayIndex.swift`, `Sotto/Files/DayIndexStore.swift`
- Test: `SottoTests/DayIndexTests.swift`

**Interfaces:**
- Produces (Tasks 2/4/5 rely on):

```swift
struct DaySegmentEntry: Codable, Sendable, Equatable {
    let id: String                    // file basename, e.g. "09-15-30"
    let startTime: Date
    var duration: TimeInterval
    var backend: String?              // nil until transcribed
    var hasAudio: Bool
    var wordCount: Int?
    var transcriptionState: String    // "queued" | "done" | "failed"
}

struct DayGapEntry: Codable, Sendable, Equatable {
    let from: Date
    let reason: String                // "uncleanShutdown"
}

struct DayIndex: Codable, Sendable, Equatable {
    let date: String                  // "2026-03-14"
    var segments: [DaySegmentEntry]
    var gaps: [DayGapEntry]
}

actor DayIndexStore {
    init(rootDirectory: URL? = nil)   // default Documents/Sotto (same as SegmentStore)
    func recordQueuedSegment(m4aURL: URL, startTime: Date, duration: TimeInterval)
    func updateSegment(m4aURL: URL, transcriptionState: String, backend: String?, wordCount: Int?)
    func setAudioRemoved(m4aURL: URL)
    func recordGap(onDayOf date: Date, from: Date, reason: String)
    func index(forDay dayDirectory: URL) -> DayIndex?      // loads _day.json (nil if absent/corrupt)
}
```

Semantics: the day directory and entry id derive from the m4a URL (`parent` / `basename`); `recordQueuedSegment` inserts (or replaces same-id) with state "queued", hasAudio true, then sorts `segments` by `startTime` and writes atomically (`_day.json` temp + rename, `.completeUntilFirstUserAuthentication` protection); `updateSegment`/`setAudioRemoved` mutate the matching entry (no-op if missing) and rewrite; `recordGap` appends to the LOCAL day folder of `date` (creating the folder + index if needed — a gap can exist on a day with no segments), sorted by `from`.

- [ ] **Step 1: Failing tests — `SottoTests/DayIndexTests.swift`**

```swift
import Foundation
import Testing
@testable import Sotto

struct DayIndexTests {
    private func tempRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("DayIndexTests-\(UUID().uuidString)")
    }

    private func m4a(_ root: URL, day: String, name: String) -> URL {
        let dir = root.appendingPathComponent(day, isDirectory: true)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(name).m4a")
    }

    @Test func recordsSortsAndPersistsSegments() async throws {
        let root = tempRoot()
        let store = DayIndexStore(rootDirectory: root)
        let later = m4a(root, day: "2026-03-14", name: "10-42-18")
        let earlier = m4a(root, day: "2026-03-14", name: "09-15-30")

        await store.recordQueuedSegment(
            m4aURL: later, startTime: Date(timeIntervalSince1970: 2_000), duration: 60)
        await store.recordQueuedSegment(
            m4aURL: earlier, startTime: Date(timeIntervalSince1970: 1_000), duration: 342)

        let index = await store.index(forDay: later.deletingLastPathComponent())
        #expect(index?.date == "2026-03-14")
        #expect(index?.segments.map(\.id) == ["09-15-30", "10-42-18"])   // sorted by startTime
        #expect(index?.segments[0].transcriptionState == "queued")
        #expect(index?.segments[0].hasAudio == true)
        // Atomic file actually exists:
        #expect(FileManager.default.fileExists(
            atPath: later.deletingLastPathComponent().appendingPathComponent("_day.json").path))
    }

    @Test func updateAndAudioRemovalMutateTheRightEntry() async throws {
        let root = tempRoot()
        let store = DayIndexStore(rootDirectory: root)
        let url = m4a(root, day: "2026-03-14", name: "09-15-30")
        await store.recordQueuedSegment(m4aURL: url, startTime: Date(), duration: 10)

        await store.updateSegment(
            m4aURL: url, transcriptionState: "done", backend: "speechAnalyzer", wordCount: 847)
        await store.setAudioRemoved(m4aURL: url)

        let entry = await store.index(forDay: url.deletingLastPathComponent())?.segments.first
        #expect(entry?.transcriptionState == "done")
        #expect(entry?.backend == "speechAnalyzer")
        #expect(entry?.wordCount == 847)
        #expect(entry?.hasAudio == false)
    }

    @Test func reRecordingSameIdReplacesNotDuplicates() async throws {
        let root = tempRoot()
        let store = DayIndexStore(rootDirectory: root)
        let url = m4a(root, day: "2026-03-14", name: "09-15-30")
        await store.recordQueuedSegment(m4aURL: url, startTime: Date(), duration: 10)
        await store.recordQueuedSegment(m4aURL: url, startTime: Date(), duration: 12)
        let index = await store.index(forDay: url.deletingLastPathComponent())
        #expect(index?.segments.count == 1)
        #expect(index?.segments[0].duration == 12)
    }

    @Test func gapsRecordOnTheirLocalDayEvenWithNoSegments() async throws {
        let root = tempRoot()
        let store = DayIndexStore(rootDirectory: root)
        let when = Date()
        await store.recordGap(onDayOf: when, from: when, reason: "uncleanShutdown")

        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.calendar = Calendar(identifier: .gregorian)
        dayFormatter.dateFormat = "yyyy-MM-dd"
        let dayDir = root.appendingPathComponent(dayFormatter.string(from: when))
        let index = await store.index(forDay: dayDir)
        #expect(index?.gaps.count == 1)
        #expect(index?.gaps[0].reason == "uncleanShutdown")
        #expect(index?.segments.isEmpty == true)
    }

    @Test func corruptIndexLoadsAsNil() async throws {
        let root = tempRoot()
        let store = DayIndexStore(rootDirectory: root)
        let dir = root.appendingPathComponent("2026-03-14")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data([0x7b, 0x00]).write(to: dir.appendingPathComponent("_day.json"))
        #expect(await store.index(forDay: dir) == nil)
    }
}
```

- [ ] **Step 2: `xcodegen generate`, RED** (`cannot find 'DayIndexStore'`).

- [ ] **Step 3: Implement.** `Sotto/Files/DayIndex.swift` = the three model structs verbatim from Interfaces. `Sotto/Files/DayIndexStore.swift`:

```swift
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
```

- [ ] **Step 4: GREEN (5 new tests), commit:** `git add Sotto/Files SottoTests/DayIndexTests.swift && git commit -m "feat: atomic _day.json index store with segments and gaps"`

---

### Task 2: DayIndexRebuilder (rebuild from .md frontmatter)

**Files:**
- Create: `Sotto/Files/DayIndexRebuilder.swift`
- Test: `SottoTests/DayIndexTests.swift` (extend)

**Interfaces:**
- Consumes: `TranscriptMarkdownWriter` output format (frontmatter keys `date`, `duration`, `backend`).
- Produces: `enum DayIndexRebuilder { static func rebuild(dayDirectory: URL) -> DayIndex }` — scans `*.md` (frontmatter → done entries with wordCount from body), plus `*.m4a` without a sibling `.md` (queued entries, startTime parsed from the basename + folder date), hasAudio = sibling m4a exists. Gaps are NOT recoverable from files (rebuilt index has `gaps: []`) — documented limitation per spec (index is "rebuildable", segments are the load-bearing part).

- [ ] **Step 1: Failing test (append to DayIndexTests)**

```swift
    @Test func rebuildsIndexFromMarkdownAndOrphanAudio() async throws {
        let root = tempRoot()
        let dir = root.appendingPathComponent("2026-03-14")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // A transcribed segment: .md (spec frontmatter) + .m4a
        let md = """
        ---
        date: 2026-03-14T09:15:30-04:00
        duration: 342
        speechEnd: 2026-03-14T09:20:12-04:00
        backend: speechAnalyzer
        ---

        # Conversation — 9:15 AM

        Hello there general conversation words here.
        """
        try md.write(to: dir.appendingPathComponent("09-15-30.md"), atomically: true, encoding: .utf8)
        try Data([0x01]).write(to: dir.appendingPathComponent("09-15-30.m4a"))
        // An untranscribed segment: audio only
        try Data([0x01]).write(to: dir.appendingPathComponent("10-42-18.m4a"))

        let index = DayIndexRebuilder.rebuild(dayDirectory: dir)

        #expect(index.date == "2026-03-14")
        #expect(index.segments.count == 2)
        let done = index.segments.first { $0.id == "09-15-30" }
        #expect(done?.transcriptionState == "done")
        #expect(done?.backend == "speechAnalyzer")
        #expect(done?.duration == 342)
        #expect(done?.hasAudio == true)
        #expect((done?.wordCount ?? 0) >= 6)                 // body words counted
        let queued = index.segments.first { $0.id == "10-42-18" }
        #expect(queued?.transcriptionState == "queued")
        #expect(queued?.wordCount == nil)
        // Sorted by startTime:
        #expect(index.segments.map(\.id) == ["09-15-30", "10-42-18"])
    }
```

- [ ] **Step 2: RED, then implement `Sotto/Files/DayIndexRebuilder.swift`**

```swift
import Foundation

/// SPEC "File output": `_day.json` is rebuildable by scanning the folder's .md frontmatter.
/// Gaps are not recoverable from files; a rebuilt index has none.
enum DayIndexRebuilder {
    static func rebuild(dayDirectory: URL) -> DayIndex {
        let date = dayDirectory.lastPathComponent
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: dayDirectory, includingPropertiesForKeys: nil)) ?? []
        let mdFiles = contents.filter { $0.pathExtension == "md" }
        let m4aFiles = contents.filter { $0.pathExtension == "m4a" }
        let mdIDs = Set(mdFiles.map { $0.deletingPathExtension().lastPathComponent })

        var segments: [DaySegmentEntry] = []

        for md in mdFiles {
            guard let text = try? String(contentsOf: md, encoding: .utf8) else { continue }
            let front = frontmatter(of: text)
            let id = md.deletingPathExtension().lastPathComponent
            let iso = ISO8601DateFormatter()
            let startTime = front["date"].flatMap { iso.date(from: $0) }
                ?? fallbackDate(dayName: date, id: id)
            segments.append(DaySegmentEntry(
                id: id,
                startTime: startTime,
                duration: front["duration"].flatMap(Double.init) ?? 0,
                backend: front["backend"],
                hasAudio: m4aFiles.contains { $0.deletingPathExtension().lastPathComponent == id },
                wordCount: wordCount(of: text),
                transcriptionState: "done"))
        }

        for m4a in m4aFiles {
            let id = m4a.deletingPathExtension().lastPathComponent
            guard !mdIDs.contains(id) else { continue }
            segments.append(DaySegmentEntry(
                id: id,
                startTime: fallbackDate(dayName: date, id: id),
                duration: 0,
                backend: nil, hasAudio: true, wordCount: nil,
                transcriptionState: "queued"))
        }

        segments.sort { $0.startTime < $1.startTime }
        return DayIndex(date: date, segments: segments, gaps: [])
    }

    private static func frontmatter(of text: String) -> [String: String] {
        let lines = text.components(separatedBy: "\n")
        guard lines.first == "---" else { return [:] }
        var result: [String: String] = [:]
        for line in lines.dropFirst() {
            if line == "---" { break }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            result[key] = value
        }
        return result
    }

    private static func wordCount(of text: String) -> Int {
        guard let bodyStart = text.range(of: "\n---\n") else { return 0 }
        let body = text[bodyStart.upperBound...]
            .replacingOccurrences(of: "#", with: " ")
        return body.split { $0.isWhitespace || $0.isNewline }.count
    }

    private static func fallbackDate(dayName: String, id: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        return formatter.date(from: "\(dayName) \(String(id.prefix(8)))") ?? .distantPast
    }
}
```

NOTE: `ISO8601DateFormatter` parses offset-carrying strings by default; the wordCount includes the "# Conversation — 9:15 AM" heading words minus '#' — the test's `>= 6` bound tolerates that; keep it loose.

- [ ] **Step 3: GREEN, commit:** `git add Sotto/Files/DayIndexRebuilder.swift SottoTests/DayIndexTests.swift && git commit -m "feat: rebuild _day.json from markdown frontmatter"`

---

### Task 3: Queue job-transition handler + relative-path persistence

**Files:**
- Modify: `Sotto/Transcription/TranscriptionQueue.swift`
- Test: `SottoTests/TranscriptionQueueTests.swift` (extend)

**Interfaces:**
- Produces:

```swift
struct JobTransition: Sendable {
    let job: TranscriptionJob            // state already updated (done/failed)
    let result: TranscriptionResult?     // non-nil on done
}
// On TranscriptionQueue:
func setTransitionHandler(_ handler: @escaping @Sendable (JobTransition) -> Void)
// init gains: rootDirectory: URL? = nil  (defaults to the Documents directory; used to
// relativize persisted paths — M4 carryover: absolute URLs break across container moves)
```

Persistence format v2: a private `PersistedJob` DTO stores `cafPath`/`m4aPath` as strings — relative to `rootDirectory` when under it, else absolute paths. Loading resolves relative paths against the CURRENT `rootDirectory` and tolerates the v1 format (absolute `cafURL`/`m4aURL` URL-encoded fields) by custom decoding. Transitions fire ONLY for `.done` (with result) and `.failed` (nil) — never for `.blocked`/still-pending.

- [ ] **Step 1: Failing tests (append to TranscriptionQueueTests)**

```swift
    @Test func transitionHandlerFiresOnDoneWithResultAndOnFailure() async throws {
        let dir = tempDir()
        let box = Mutex<[String]>([])
        let queue = TranscriptionQueue(
            storeURL: dir.appendingPathComponent("jobs.json"),
            service: FakeTranscriptionService(text: "words here"),
            rootDirectory: dir)
        await queue.setTransitionHandler { transition in
            box.withLock { $0.append("\(transition.job.state.rawValue):\(transition.result?.text ?? "-")") }
        }
        await queue.enqueue(try makeSegment(in: dir.appendingPathComponent("a")))
        await queue.drain()
        #expect(box.withLock { $0 } == ["done:words here"])

        let failing = TranscriptionQueue(
            storeURL: dir.appendingPathComponent("jobs2.json"),
            service: FakeTranscriptionService(text: "x", failuresBeforeSuccess: .max),
            maxAttempts: 1, rootDirectory: dir)
        await failing.setTransitionHandler { transition in
            box.withLock { $0.append("\(transition.job.state.rawValue):\(transition.result?.text ?? "-")") }
        }
        await failing.enqueue(try makeSegment(in: dir.appendingPathComponent("b")))
        await failing.drain()
        #expect(box.withLock { $0 }.last == "failed:-")
    }

    @Test func persistedPathsAreRelativeAndSurviveRootMove() async throws {
        let dirA = tempDir()
        let store = dirA.appendingPathComponent("jobs.json")
        let queue = TranscriptionQueue(
            storeURL: store,
            service: FakeTranscriptionService(text: "x", failuresBeforeSuccess: .max),
            maxAttempts: 99, rootDirectory: dirA)
        await queue.enqueue(try makeSegment(in: dirA.appendingPathComponent("seg")))

        // The persisted file must not contain the absolute temp path:
        let raw = try String(contentsOf: store, encoding: .utf8)
        #expect(!raw.contains(dirA.path))

        // Simulate a container move: copy the whole root elsewhere and reload.
        let dirB = tempDir()
        try FileManager.default.copyItem(at: dirA, to: dirB)
        let moved = TranscriptionQueue(
            storeURL: dirB.appendingPathComponent("jobs.json"),
            service: FakeTranscriptionService(text: "recovered"),
            rootDirectory: dirB)
        await moved.drain()
        #expect(await moved.jobs.first?.state == .done)   // paths resolved at the NEW root
    }

    @Test func legacyAbsoluteURLJobsStillLoad() async throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let m4a = dir.appendingPathComponent("old.m4a")
        // v1 format: Codable-encoded URLs (relative strings absent)
        let v1 = """
        [{"id":"\(UUID().uuidString)","cafURL":null,"m4aURL":{"relative":"\(m4a.absoluteString)"},
          "startDate":700000000,"duration":5,"speechDuration":5,"attempts":0,"state":"pending"}]
        """
        try Data(v1.utf8).write(to: dir.appendingPathComponent("jobs.json"))
        let queue = TranscriptionQueue(
            storeURL: dir.appendingPathComponent("jobs.json"),
            service: FakeTranscriptionService(text: "x"), rootDirectory: dir)
        #expect(await queue.jobs.count == 1)
        #expect(await queue.jobs.first?.m4aURL.lastPathComponent == "old.m4a")
    }
```

NOTE on the v1 fixture: Foundation encodes `URL` as `{"relative": "..."}` or a plain string depending on base — the implementer must check what the CURRENT code actually produced (write a job with the pre-change build if unsure, or read JSONEncoder's URL behavior: top-level URL in a keyed container encodes as a single string via `URL`'s Codable which uses `absoluteString`). ADJUST the fixture to the real v1 shape (likely `"m4aURL":"file:///…"` as a plain string) and note it. The binding requirement is: a jobs.json written by the previous build loads.

- [ ] **Step 2: RED, implement.** In `TranscriptionQueue`: add `private let rootDirectory: URL` (init param default `FileManager.default.urls(for: .documentDirectory, ...)[0]`), `private var transitionHandler: (@Sendable (JobTransition) -> Void)?` + `setTransitionHandler`. Fire in `step`: after `.done` is set (`transitionHandler?(JobTransition(job: jobs[index], result: result))`) and inside `fail(...)` when the threshold marks `.failed` (`transitionHandler?(JobTransition(job: jobs[index], result: nil))`). Persistence:

```swift
    private struct PersistedJob: Codable {
        let id: UUID
        let cafPath: String?
        let m4aPath: String
        let startDate: Date
        let duration: TimeInterval
        let speechDuration: TimeInterval
        let attempts: Int
        let state: TranscriptionJob.State

        // v1 tolerance: absolute URL fields from the previous build.
        enum CodingKeys: String, CodingKey {
            case id, cafPath, m4aPath, startDate, duration, speechDuration, attempts, state
            case cafURL, m4aURL
        }

        init(job: TranscriptionJob, root: URL) {
            id = job.id
            cafPath = job.cafURL.map { Self.relativize($0, root: root) }
            m4aPath = Self.relativize(job.m4aURL, root: root)
            startDate = job.startDate
            duration = job.duration
            speechDuration = job.speechDuration
            attempts = job.attempts
            state = job.state
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(UUID.self, forKey: .id)
            startDate = try container.decode(Date.self, forKey: .startDate)
            duration = try container.decode(TimeInterval.self, forKey: .duration)
            speechDuration = try container.decode(TimeInterval.self, forKey: .speechDuration)
            attempts = try container.decode(Int.self, forKey: .attempts)
            state = try container.decode(TranscriptionJob.State.self, forKey: .state)
            if let path = try container.decodeIfPresent(String.self, forKey: .m4aPath) {
                m4aPath = path
                cafPath = try container.decodeIfPresent(String.self, forKey: .cafPath)
            } else {
                // v1: URL-encoded absolute fields
                let m4a = try container.decode(URL.self, forKey: .m4aURL)
                m4aPath = m4a.path
                cafPath = try container.decodeIfPresent(URL.self, forKey: .cafURL)?.path
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encodeIfPresent(cafPath, forKey: .cafPath)
            try container.encode(m4aPath, forKey: .m4aPath)
            try container.encode(startDate, forKey: .startDate)
            try container.encode(duration, forKey: .duration)
            try container.encode(speechDuration, forKey: .speechDuration)
            try container.encode(attempts, forKey: .attempts)
            try container.encode(state, forKey: .state)
        }

        static func relativize(_ url: URL, root: URL) -> String {
            let path = url.standardizedFileURL.path
            let rootPath = root.standardizedFileURL.path
            return path.hasPrefix(rootPath + "/")
                ? String(path.dropFirst(rootPath.count + 1))
                : path
        }

        func job(root: URL) -> TranscriptionJob {
            func resolve(_ path: String) -> URL {
                path.hasPrefix("/") ? URL(fileURLWithPath: path)
                    : root.appendingPathComponent(path)
            }
            return TranscriptionJob(
                id: id, cafURL: cafPath.map(resolve), m4aURL: resolve(m4aPath),
                startDate: startDate, duration: duration, speechDuration: speechDuration,
                attempts: attempts, state: state)
        }
    }
```

`persist()` encodes `jobs.map { PersistedJob(job: $0, root: rootDirectory) }`; init decodes `[PersistedJob]` and maps `.job(root: rootDirectory)` (keep the old direct-`[TranscriptionJob]` decode as a second fallback in a `??` chain for safety). Update existing queue tests to pass `rootDirectory: dir` where they construct queues (mechanical).

- [ ] **Step 3: GREEN (3 new tests + all prior), commit:** `git add Sotto/Transcription/TranscriptionQueue.swift SottoTests/TranscriptionQueueTests.swift && git commit -m "feat: queue transition handler and container-move-safe job persistence"`

---

### Task 4: Retention policy + backup exclusion

**Files:**
- Create: `Sotto/Files/RetentionPolicy.swift`
- Modify: `Sotto/Segments/CAFSegmentWriter.swift` (backup exclusion in `transcodeToM4A`)
- Test: `SottoTests/RetentionTests.swift`

**Interfaces:**
- Produces:

```swift
enum AudioRetention: String, Codable, CaseIterable, Sendable {
    case deleteAfterTranscription   // SPEC default
    case keepSevenDays
    case keepForever
}

struct SettingsStore: Sendable {
    let defaults: UserDefaults
    init(defaults: UserDefaults = .standard)
    var audioRetention: AudioRetention { get nonmutating set }   // UserDefaults-backed
}

enum RetentionEnforcer {
    /// Post-transcription hook: returns true when the audio was deleted.
    static func applyAfterTranscription(m4aURL: URL, retention: AudioRetention) -> Bool
    /// Launch sweep for keepSevenDays: deletes m4a older than 7 days THAT HAVE a sibling
    /// .md (never deletes untranscribed audio). Returns deleted URLs.
    static func sweep(root: URL, retention: AudioRetention, now: Date = Date()) -> [URL]
}
```

- [ ] **Step 1: Failing tests — `SottoTests/RetentionTests.swift`**

```swift
import Foundation
import Testing
@testable import Sotto

struct RetentionTests {
    private func tempRoot() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RetentionTests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func settingsDefaultToDeleteAfterTranscription() {
        let suite = UserDefaults(suiteName: "retention-tests-\(UUID().uuidString)")!
        let settings = SettingsStore(defaults: suite)
        #expect(settings.audioRetention == .deleteAfterTranscription)
        settings.audioRetention = .keepSevenDays
        #expect(settings.audioRetention == .keepSevenDays)
    }

    @Test func applyAfterTranscriptionDeletesOnlyUnderDefaultPolicy() throws {
        let root = tempRoot()
        for retention in AudioRetention.allCases {
            let url = root.appendingPathComponent("\(retention.rawValue).m4a")
            try Data([0x01]).write(to: url)
            let deleted = RetentionEnforcer.applyAfterTranscription(m4aURL: url, retention: retention)
            #expect(deleted == (retention == .deleteAfterTranscription))
            #expect(FileManager.default.fileExists(atPath: url.path) == !deleted)
        }
    }

    @Test func sevenDaySweepDeletesOldTranscribedAudioOnly() throws {
        let root = tempRoot()
        let day = root.appendingPathComponent("2026-01-01")
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let oldDone = day.appendingPathComponent("01-00-00.m4a")
        let oldPending = day.appendingPathComponent("02-00-00.m4a")
        try Data([1]).write(to: oldDone)
        try Data([1]).write(to: oldPending)
        try "x".write(to: day.appendingPathComponent("01-00-00.md"), atomically: true, encoding: .utf8)
        let past = Date(timeIntervalSinceNow: -8 * 86_400)
        try FileManager.default.setAttributes([.creationDate: past], ofItemAtPath: oldDone.path)
        try FileManager.default.setAttributes([.creationDate: past], ofItemAtPath: oldPending.path)

        let deleted = RetentionEnforcer.sweep(root: root, retention: .keepSevenDays)

        #expect(deleted == [oldDone])                        // transcribed + old → deleted
        #expect(FileManager.default.fileExists(atPath: oldPending.path))   // never delete untranscribed
        // Other policies sweep nothing:
        #expect(RetentionEnforcer.sweep(root: root, retention: .keepForever).isEmpty)
        #expect(RetentionEnforcer.sweep(root: root, retention: .deleteAfterTranscription).isEmpty)
    }

    @Test func transcodedM4AIsExcludedFromBackup() throws {
        let root = tempRoot()
        let caf = root.appendingPathComponent("a.caf")
        let m4a = root.appendingPathComponent("a.m4a")
        let writer = try CAFSegmentWriter(cafURL: caf, m4aURL: m4a)
        try writer.append([Float](repeating: 0.1, count: VADConstants.sampleRate))
        writer.close()
        try CAFSegmentWriter.transcodeToM4A(caf: caf, m4a: m4a)
        let values = try m4a.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)         // SPEC backup policy: audio excluded
    }
}
```

- [ ] **Step 2: RED, implement.** `Sotto/Files/RetentionPolicy.swift`:

```swift
import Foundation

/// SPEC "File output" retention: audio default = delete after transcription; transcripts
/// keep forever (nothing here ever touches .md/_day.json).
enum AudioRetention: String, Codable, CaseIterable, Sendable {
    case deleteAfterTranscription
    case keepSevenDays
    case keepForever
}

struct SettingsStore: Sendable {
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var audioRetention: AudioRetention {
        get {
            defaults.string(forKey: "audioRetention")
                .flatMap(AudioRetention.init(rawValue:)) ?? .deleteAfterTranscription
        }
        nonmutating set {
            defaults.set(newValue.rawValue, forKey: "audioRetention")
        }
    }
}

enum RetentionEnforcer {
    static func applyAfterTranscription(m4aURL: URL, retention: AudioRetention) -> Bool {
        guard retention == .deleteAfterTranscription else { return false }
        return (try? FileManager.default.removeItem(at: m4aURL)) != nil
    }

    static func sweep(root: URL, retention: AudioRetention, now: Date = Date()) -> [URL] {
        guard retention == .keepSevenDays else { return [] }
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.creationDateKey]) else { return [] }
        var deleted: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "m4a" {
            let md = url.deletingPathExtension().appendingPathExtension("md")
            guard FileManager.default.fileExists(atPath: md.path) else { continue }   // never delete untranscribed
            let created = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? now
            guard now.timeIntervalSince(created) > 7 * 86_400 else { continue }
            if (try? FileManager.default.removeItem(at: url)) != nil {
                deleted.append(url)
            }
        }
        return deleted
    }
}
```

In `CAFSegmentWriter.transcodeToM4A`, next to the protection attribute:

```swift
        // SPEC backup policy: audio is bulky and the transcript is the product — exclude
        // every produced m4a from iCloud/device backup (transcripts + _day.json stay in).
        var backupValues = URLResourceValues()
        backupValues.isExcludedFromBackup = true
        var mutableM4A = m4a
        try? mutableM4A.setResourceValues(backupValues)
```

- [ ] **Step 3: GREEN (4 new tests), commit:** `git add Sotto/Files/RetentionPolicy.swift Sotto/Segments/CAFSegmentWriter.swift SottoTests/RetentionTests.swift && git commit -m "feat: audio retention policy and backup exclusion"`

---

### Task 5: AppModel wiring + integration + e2e

**Files:**
- Modify: `Sotto/App/AppModel.swift`
- Modify: `SottoTests/RecorderIntegrationTests.swift` (extend the whole-stack test through the index)
- Test: full suite; simulator e2e

**Interfaces:**
- Consumes: everything above. AppModel gains `private(set) var dayIndex: DayIndexStore?` and `let settings = SettingsStore()`.

- [ ] **Step 1: Wiring in `AppModel.performSetUp()`:**

1. Construct `let dayIndexStore = DayIndexStore()` right after `SegmentStore()`; assign `self.dayIndex = dayIndexStore`.
2. Unclean-shutdown branch: capture the heartbeat BEFORE clearing and record the gap (this is the spec's `gap` entry — the heartbeat timestamp is when listening died):

```swift
        if heartbeat.indicatesUncleanShutdown {
            if let beat = heartbeat.read() {
                await dayIndexStore.recordGap(
                    onDayOf: beat.timestamp, from: beat.timestamp, reason: "uncleanShutdown")
            }
            // …existing salvaged-count notice + heartbeat.clear() unchanged…
        }
```

3. Salvaged m4as: they're already enqueued via `enqueueSalvaged`; ALSO record them in the index (state queued). After the existing salvage-enqueue loop, for each salvaged URL: read the job the queue created — simpler: `recordQueuedSegment(m4aURL: url, startTime: <same parse the queue does>, duration: 0)`. To avoid duplicating the parse, extend `TranscriptionQueue.enqueueSalvaged` to RETURN the created `TranscriptionJob?` and use its fields:

```swift
        for url in salvaged {
            if let job = await transcriptionQueue.enqueueSalvaged(m4aURL: url) {
                await dayIndexStore.recordQueuedSegment(
                    m4aURL: job.m4aURL, startTime: job.startDate, duration: job.duration)
            }
        }
```

(change `enqueueSalvaged`'s signature to `@discardableResult func enqueueSalvaged(m4aURL: URL) -> TranscriptionJob?`, returning nil on duplicate — update its Task 3-era tests accordingly if signatures collide; behavior unchanged.)
4. Segment handler: record queued + enqueue + drain:

```swift
            let settings = self.settings
            await recorder.setSegmentHandler { segment in
                Task {
                    await dayIndexStore.recordQueuedSegment(
                        m4aURL: segment.m4aURL,
                        startTime: segment.startDate,
                        duration: segment.duration)
                    await transcriptionQueue.enqueue(segment)
                    await transcriptionQueue.drain()
                }
            }
```

5. Transition handler (before the gated drain):

```swift
            await transcriptionQueue.setTransitionHandler { transition in
                Task {
                    let wordCount = transition.result.map {
                        $0.text.split { $0.isWhitespace || $0.isNewline }.count
                    }
                    await dayIndexStore.updateSegment(
                        m4aURL: transition.job.m4aURL,
                        transcriptionState: transition.job.state.rawValue,
                        backend: transition.result?.backend.rawValue,
                        wordCount: wordCount)
                    if transition.job.state == .done,
                       RetentionEnforcer.applyAfterTranscription(
                           m4aURL: transition.job.m4aURL, retention: settings.audioRetention) {
                        await dayIndexStore.setAudioRemoved(m4aURL: transition.job.m4aURL)
                    }
                }
            }
```

6. Launch sweep, after everything (fire-and-forget): `Task.detached { _ = RetentionEnforcer.sweep(root: store.rootDirectory, retention: settings.audioRetention) }`.
(`SettingsStore` must be a `let settings = SettingsStore()` stored property on AppModel.)

- [ ] **Step 2: Extend `RecorderIntegrationTests`:** in the whole-stack test, construct a `DayIndexStore(rootDirectory: root)` and mirror AppModel's two handlers (segment → recordQueuedSegment + enqueue + drain; transition → updateSegment + applyAfterTranscription with `.deleteAfterTranscription` + setAudioRemoved). Final assertions to ADD: `_day.json` exists in the day folder; its single entry has `transcriptionState == "done"`, a positive `wordCount`, `hasAudio == false` (default retention deleted the audio), and the m4a is gone while the `.md` remains.

- [ ] **Step 3: Full suite green, commit:** `git add Sotto SottoTests && git commit -m "feat: wire day index, gap entries, and retention into the app model"`

- [ ] **Step 4: e2e:** build, install, launch on iPhone Air; screenshot to the session scratchpad; `log show` crash check. On this asset-less simulator, a recorded segment stays `queued` in `_day.json` with `hasAudio: true` — correct behavior to report.

## Self-review notes

- Spec "File output" coverage: atomic rebuildable `_day.json` ✓ (T1+T2); local-date folders ✓ (pre-existing); backup policy ✓ (T4 + transcripts untouched); retention ✓ (T4, default deleteAfterTranscription; transcripts never deleted); gaps `{from, reason: uncleanShutdown}` ✓ (T1 + T5 heartbeat timestamp); Files-app exposure ✓ (Info.plist keys since M1); disk guard ✓ (recorder since M2). Deferred to M6 (UI-coupled per spec's Settings/List screens): retention picker, storage-used readout, gap markers rendering, failed-row retry.
- Carryovers closed: relative jobs.json ✓ (T3); transition signal ✓ (T3); salvage gap/index entries ✓ (T5); wordCount ✓ (T5 computes from result text); _day.json sorted by startTime ✓ (T1) — closing the out-of-order-enqueue concern.
- Type consistency: `DayIndexStore` method names identical across T1/T5; `JobTransition { job, result }` matches both test and wiring usage; `enqueueSalvaged` return-type change is called out where it lands (T5) with test-update instruction.

# Merge Conversations Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user multi-select 2+ same-day conversations and merge them into one — transcript concatenation with gap markers, audio stitched when every part still has it, notes regenerated best-effort, sync mirror kept consistent.

**Architecture:** New file-level unit `ConversationMerger` (Sotto/Files) owns stitch → write merged .md → move audio → delete parts; `DayIndexStore.applyMerge` owns the `_day.json` update (the actor owns index writes); `AppModel.mergeSegments` orchestrates (index, queue, PreviewCache, mirror, notes regen, history refresh); `ContentView` gains edit-mode multi-select + Merge bar. The merged file uses EXACTLY the frontmatter keys of a recorded file, so rebuild/list/preview/sync work on it unchanged.

**Tech Stack:** Swift 6 (`SWIFT_DEFAULT_ACTOR_ISOLATION: nonisolated`), SwiftUI, AVFoundation (stitch), Swift Testing (`import Testing`, `@Test`, `#expect`), XcodeGen.

**Spec:** `docs/superpowers/specs/2026-07-06-merge-conversations-design.md` — read it first.

## Global Constraints

- Test command (every task): `xcodebuild test -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone Air' 2>&1 | tail -5` → `** TEST SUCCEEDED **`. Runs take minutes; not a hang. Simulator Busy → `xcrun simctl shutdown all`, retry. Scope with `-only-testing:SottoTests/<Suite>` while iterating.
- New source files → run `xcodegen generate` before building (sources are path-globbed).
- Zero Swift warnings. iOS 26 deployment target.
- All `DateFormatter`s pinned: `Locale(identifier: "en_US_POSIX")` (+ Gregorian calendar where day/date math matters) — never locale-following.
- Every file written to the store: atomic write (`atomically: true` / temp+rename), then `FileProtectionType.completeUntilFirstUserAuthentication` via `setAttributes` (see `TranscriptMarkdownWriter.write` for the pattern).
- Never lose user data mid-operation: create the new truth before deleting the old (spec "Operation ordering").
- All sync-mirror work: best-effort, `NSFileCoordinator`-coordinated, `Task.detached(priority: .utility)`, never throws into a caller, never rides the main actor.
- Simulator has no FoundationModels — notes-related code must be testable without it (`ConversationMerger.applyNotes` takes a `PostProcessingResult` directly).
- Commit after every task. Frontmatter parsing goes through `TranscriptFile.parse` — never a second parser.

---

### Task 1: AudioStitcher

**Files:**
- Create: `Sotto/Audio/AudioStitcher.swift`
- Test: `SottoTests/AudioStitcherTests.swift`

**Interfaces:**
- Consumes: nothing project-internal (AVFoundation only). Tests reuse `CAFSegmentWriter` (`Sotto/Segments/CAFSegmentWriter.swift`) to fabricate real .m4a fixtures — same trick as `AppModel.testDeepgramKey` (AppModel.swift:336).
- Produces: `enum AudioStitcher { static func stitch(parts: [URL], to output: URL) async throws }` and `AudioStitcher.StitchError` — Task 3 calls this.

- [ ] **Step 1: Write the failing test**

Create `SottoTests/AudioStitcherTests.swift`:

```swift
import AVFoundation
import Foundation
import Testing
@testable import Sotto

struct AudioStitcherTests {
    /// Real .m4a fixture the same way testDeepgramKey fabricates one: CAF write → transcode.
    private func makeM4A(seconds: Double, in dir: URL, name: String) throws -> URL {
        let cafURL = dir.appendingPathComponent("\(name).caf")
        let m4aURL = dir.appendingPathComponent("\(name).m4a")
        let writer = try CAFSegmentWriter(cafURL: cafURL, m4aURL: m4aURL)
        try writer.append([Float](repeating: 0, count: Int(seconds * Double(VADConstants.sampleRate))))
        writer.close()
        try CAFSegmentWriter.transcodeToM4A(caf: cafURL, m4a: m4aURL)
        try FileManager.default.removeItem(at: cafURL)
        return m4aURL
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("StitcherTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func stitchedDurationIsSumOfParts() async throws {
        let dir = try tempDir()
        let a = try makeM4A(seconds: 0.5, in: dir, name: "a")
        let b = try makeM4A(seconds: 0.75, in: dir, name: "b")
        let output = dir.appendingPathComponent("out.m4a")

        try await AudioStitcher.stitch(parts: [a, b], to: output)

        #expect(FileManager.default.fileExists(atPath: output.path))
        let duration = try await AVURLAsset(url: output).load(.duration).seconds
        #expect(abs(duration - 1.25) < 0.2)   // AAC priming/frame padding tolerance
    }

    @Test func unreadablePartThrows() async throws {
        let dir = try tempDir()
        let good = try makeM4A(seconds: 0.5, in: dir, name: "good")
        let garbage = dir.appendingPathComponent("garbage.m4a")
        try Data([0x00, 0x01]).write(to: garbage)
        let output = dir.appendingPathComponent("out.m4a")

        await #expect(throws: (any Error).self) {
            try await AudioStitcher.stitch(parts: [good, garbage], to: output)
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodegen generate && xcodebuild test -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone Air' -only-testing:SottoTests/AudioStitcherTests 2>&1 | tail -5`
Expected: BUILD FAILURE — `cannot find 'AudioStitcher' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sotto/Audio/AudioStitcher.swift`:

```swift
import AVFoundation
import Foundation

/// Merge-conversations (spec 2026-07-06): concatenates same-pipeline .m4a segments into
/// one file. Passthrough preset first — every part comes from the same
/// CAFSegmentWriter→AAC pipeline, so a re-encode is normally unnecessary — with an AAC
/// re-encode fallback for environments that reject passthrough (seen on simulators).
/// Throws when any part is unreadable or both exports fail; callers treat any throw as
/// "abort the merge, nothing changed".
enum AudioStitcher {
    enum StitchError: Error {
        case noParts
        case unreadablePart(URL)
        case exportFailed(String)
    }

    static func stitch(parts: [URL], to output: URL) async throws {
        guard !parts.isEmpty else { throw StitchError.noParts }
        let composition = AVMutableComposition()
        var cursor = CMTime.zero
        for part in parts {
            let asset = AVURLAsset(url: part)
            let duration = try await asset.load(.duration)
            guard duration > .zero else { throw StitchError.unreadablePart(part) }
            do {
                try composition.insertTimeRange(
                    CMTimeRange(start: .zero, duration: duration), of: asset, at: cursor)
            } catch {
                throw StitchError.unreadablePart(part)
            }
            cursor = cursor + duration
        }
        do {
            try await export(composition, preset: AVAssetExportPresetPassthrough, to: output)
        } catch {
            try? FileManager.default.removeItem(at: output)
            try await export(composition, preset: AVAssetExportPresetAppleM4A, to: output)
        }
    }

    private static func export(
        _ composition: AVMutableComposition, preset: String, to output: URL
    ) async throws {
        guard let session = AVAssetExportSession(asset: composition, presetName: preset) else {
            throw StitchError.exportFailed("no export session for \(preset)")
        }
        try await session.export(to: output, as: .m4a)
    }
}
```

ADAPT-ALLOWED: `session.export(to:as:)` is the iOS 18+ async API. If the SDK complains, fall back to `session.outputURL = output; session.outputFileType = .m4a; try await session.export()` — keep the passthrough-then-re-encode structure either way. If `unreadablePartThrows` leaves a partial `out.m4a` on disk after the fallback attempt, add `try? FileManager.default.removeItem(at: output)` before re-throwing from `stitch`.

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone Air' -only-testing:SottoTests/AudioStitcherTests 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add Sotto/Audio/AudioStitcher.swift SottoTests/AudioStitcherTests.swift
git commit -m "feat: AudioStitcher — concatenate .m4a segments with passthrough + re-encode fallback"
```

---

### Task 2: ConversationMerger — transcript-only merge

**Files:**
- Create: `Sotto/Files/ConversationMerger.swift`
- Modify: `Sotto/Files/DayIndexRebuilder.swift:58` (make `wordCount` internal)
- Test: `SottoTests/ConversationMergerTests.swift`

**Interfaces:**
- Consumes: `TranscriptFile.parse(url:)`, `TranscriptFile.transcriptBody`, `DaySegmentEntry`, `DayIndexRebuilder.wordCount(of:)` (made internal here), `AudioStitcher.stitch(parts:to:)` (Task 1; the audio path is exercised in Task 3 but the code lands now, complete).
- Produces:
  - `ConversationMerger.merge(dayDirectory: URL, entries: [DaySegmentEntry]) async throws -> ConversationMerger.Outcome`
  - `struct Outcome { let mergedEntry: DaySegmentEntry; let removedIDs: [String]; let mergedM4AURL: URL }`
  - `enum MergeError: Error, Equatable { case needAtLeastTwoParts, missingTranscript(String), audioStitchFailed(String) }`
  - Tasks 3–5 and 8 build on these exact names.

- [ ] **Step 1: Make `DayIndexRebuilder.wordCount` internal**

In `Sotto/Files/DayIndexRebuilder.swift`, change line 58 from:

```swift
    private static func wordCount(of body: String) -> Int {
```

to:

```swift
    static func wordCount(of body: String) -> Int {
```

(The merger computes the merged entry's `wordCount` with the SAME function the rebuilder uses, on the SAME parsed text — rebuild parity by construction, not by coincidence.)

- [ ] **Step 2: Write the failing tests**

Create `SottoTests/ConversationMergerTests.swift`:

```swift
import Foundation
import Testing
@testable import Sotto

struct ConversationMergerTests {
    /// Fixture day folder. Entries are derived via DayIndexRebuilder.rebuild — the same
    /// startTime/duration the app itself would hold for these files.
    private func makeDay(_ files: [(id: String, markdown: String)]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MergerTests-\(UUID().uuidString)")
            .appendingPathComponent("2026-03-14", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for file in files {
            try file.markdown.write(
                to: dir.appendingPathComponent("\(file.id).md"),
                atomically: true, encoding: .utf8)
        }
        return dir
    }

    private let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "h:mm a"
        return formatter
    }()

    // Part 1: 09:15:30 → speechEnd 09:20:00. Part 2: starts 10:01:00 → gap 41 min.
    static let partOne = """
    ---
    date: 2026-03-14T09:15:30-04:00
    duration: 270
    speechEnd: 2026-03-14T09:20:00-04:00
    backend: speechAnalyzer
    ---

    # Conversation — 9:15 AM

    First part text one two three.
    """

    static let partTwo = """
    ---
    date: 2026-03-14T10:01:00-04:00
    duration: 120
    speechEnd: 2026-03-14T10:03:00-04:00
    backend: speechAnalyzer
    ---

    # Conversation — 10:01 AM

    Second part text four five.
    """

    @Test func mergesTwoTranscriptsWithGapMarker() async throws {
        let dir = try makeDay([("09-15-30", Self.partOne), ("10-01-00", Self.partTwo)])
        let entries = DayIndexRebuilder.rebuild(dayDirectory: dir).segments

        let outcome = try await ConversationMerger.merge(dayDirectory: dir, entries: entries)

        #expect(outcome.mergedEntry.id == "09-15-30")
        #expect(outcome.removedIDs == ["10-01-00"])
        #expect(outcome.mergedEntry.duration == 390)          // 270 + 120, summed not spanned
        #expect(outcome.mergedEntry.backend == "speechAnalyzer")
        #expect(outcome.mergedEntry.hasAudio == false)
        #expect(outcome.mergedEntry.transcriptionState == "done")
        #expect(outcome.mergedEntry.title == nil)
        #expect(!FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("10-01-00.md").path))

        let merged = try #require(TranscriptFile.parse(
            url: dir.appendingPathComponent("09-15-30.md")))
        #expect(merged.frontmatter["date"] == "2026-03-14T09:15:30-04:00")
        #expect(merged.frontmatter["duration"] == "390")
        #expect(merged.frontmatter["speechEnd"] == "2026-03-14T10:03:00-04:00")
        #expect(merged.frontmatter["backend"] == "speechAnalyzer")
        #expect(merged.frontmatter["title"] == nil)
        #expect(merged.frontmatter["speakers"] == nil)

        let resumed = timeFormatter.string(from: entries[1].startTime)
        #expect(merged.body.contains("> 41 min gap — resumed \(resumed)"))
        #expect(merged.body.contains("First part text one two three."))
        #expect(merged.body.contains("Second part text four five."))
        // Exactly ONE heading: the parts' own H1 lines are dropped.
        let headings = merged.body.components(separatedBy: "\n").filter { $0.hasPrefix("# ") }
        let started = timeFormatter.string(from: entries[0].startTime)
        #expect(headings == ["# Conversation — \(started)"])
    }

    @Test func mixedBackendsAndSpeakersComputeHonestFrontmatter() async throws {
        let deepgramPart = """
        ---
        date: 2026-03-14T11:00:00-04:00
        duration: 60
        speechEnd: 2026-03-14T11:01:00-04:00
        backend: deepgram
        speakers: 2
        ---

        # Conversation — 11:00 AM

        **Speaker 0:** Hello there.

        **Speaker 1:** Hi.
        """
        let dir = try makeDay([("09-15-30", Self.partOne), ("11-00-00", deepgramPart)])
        let entries = DayIndexRebuilder.rebuild(dayDirectory: dir).segments

        let outcome = try await ConversationMerger.merge(dayDirectory: dir, entries: entries)

        let merged = try #require(TranscriptFile.parse(
            url: dir.appendingPathComponent("09-15-30.md")))
        #expect(merged.frontmatter["backend"] == "mixed")
        #expect(outcome.mergedEntry.backend == "mixed")
        #expect(merged.frontmatter["speakers"] == "2")        // max across parts that have it
        // Reset note requires labels on BOTH sides of the gap — part 1 has none.
        #expect(!merged.body.contains("speaker numbers restart"))
        #expect(merged.body.contains("**Speaker 0:** Hello there."))   // labels untouched
    }

    @Test func speakerResetNoteAppearsBetweenTwoDiarizedParts() async throws {
        func diarized(dateLine: String, endLine: String, text: String) -> String {
            """
            ---
            date: \(dateLine)
            duration: 60
            speechEnd: \(endLine)
            backend: deepgram
            speakers: 2
            ---

            # Conversation

            **Speaker 0:** \(text)
            """
        }
        let dir = try makeDay([
            ("09-00-00", diarized(dateLine: "2026-03-14T09:00:00-04:00",
                                  endLine: "2026-03-14T09:01:00-04:00", text: "First.")),
            ("10-31-00", diarized(dateLine: "2026-03-14T10:31:00-04:00",
                                  endLine: "2026-03-14T10:32:00-04:00", text: "Second.")),
        ])
        let entries = DayIndexRebuilder.rebuild(dayDirectory: dir).segments

        _ = try await ConversationMerger.merge(dayDirectory: dir, entries: entries)

        let merged = try #require(TranscriptFile.parse(
            url: dir.appendingPathComponent("09-00-00.md")))
        let resumed = timeFormatter.string(from: entries[1].startTime)
        #expect(merged.body.contains(
            "> 1 hr 30 min gap — resumed \(resumed) · speaker numbers restart"))
        #expect(merged.frontmatter["speakers"] == "2")        // max(2, 2), NOT sum
    }

    @Test func perPartNotesSectionsAreStripped() async throws {
        let notesPart = """
        ---
        date: 2026-03-14T10:01:00-04:00
        duration: 120
        speechEnd: 2026-03-14T10:03:00-04:00
        backend: speechAnalyzer
        title: Old Title
        ---

        # Old Title — 10:01 AM

        ## Summary

        Old summary that must not survive.

        ## Transcript

        Second part text four five.
        """
        let dir = try makeDay([("09-15-30", Self.partOne), ("10-01-00", notesPart)])
        let entries = DayIndexRebuilder.rebuild(dayDirectory: dir).segments

        _ = try await ConversationMerger.merge(dayDirectory: dir, entries: entries)

        let merged = try #require(TranscriptFile.parse(
            url: dir.appendingPathComponent("09-15-30.md")))
        #expect(!merged.body.contains("Old summary"))
        #expect(!merged.body.contains("Old Title"))
        #expect(merged.frontmatter["title"] == nil)
        #expect(merged.body.contains("Second part text four five."))
    }

    @Test func fewerThanTwoPartsThrows() async throws {
        let dir = try makeDay([("09-15-30", Self.partOne)])
        let entries = DayIndexRebuilder.rebuild(dayDirectory: dir).segments
        await #expect(throws: ConversationMerger.MergeError.needAtLeastTwoParts) {
            _ = try await ConversationMerger.merge(dayDirectory: dir, entries: entries)
        }
    }

    @Test func missingTranscriptAbortsWithoutTouchingDisk() async throws {
        let dir = try makeDay([("09-15-30", Self.partOne)])
        let ghost = DaySegmentEntry(
            id: "10-01-00", startTime: Date(), duration: 120, backend: "speechAnalyzer",
            hasAudio: false, wordCount: 5, transcriptionState: "done")
        var entries = DayIndexRebuilder.rebuild(dayDirectory: dir).segments
        entries.append(ghost)

        await #expect(throws: ConversationMerger.MergeError.missingTranscript("10-01-00")) {
            _ = try await ConversationMerger.merge(dayDirectory: dir, entries: entries)
        }
        // Part 1 untouched — abort happens before any write.
        let survivor = try String(
            contentsOf: dir.appendingPathComponent("09-15-30.md"), encoding: .utf8)
        #expect(survivor.contains("First part text one two three."))
        #expect(!survivor.contains("gap"))
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `xcodebuild test -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone Air' -only-testing:SottoTests/ConversationMergerTests 2>&1 | tail -5`
Expected: BUILD FAILURE — `cannot find 'ConversationMerger' in scope`.

- [ ] **Step 4: Write the implementation**

Create `Sotto/Files/ConversationMerger.swift`:

```swift
import Foundation

/// Merge-conversations (spec 2026-07-06): file-level merge of 2+ same-day conversations
/// into the earliest part's basename. Owns spec steps 1–4 (stitch → write merged .md →
/// move audio → delete parts); step 5 (`_day.json`) stays with `DayIndexStore.applyMerge`,
/// the actor that owns index writes. The merged file uses EXACTLY a recorded file's
/// frontmatter keys, so rebuild/list/preview/sync treat it as any other conversation.
enum ConversationMerger {
    enum MergeError: Error, Equatable {
        case needAtLeastTwoParts
        case missingTranscript(String)      // part id whose .md is unreadable
        case audioStitchFailed(String)
    }

    struct Outcome: Equatable {
        let mergedEntry: DaySegmentEntry
        let removedIDs: [String]            // part ids whose files were deleted
        let mergedM4AURL: URL               // exists only when mergedEntry.hasAudio
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "h:mm a"
        return formatter
    }()

    static func merge(dayDirectory: URL, entries: [DaySegmentEntry]) async throws -> Outcome {
        guard entries.count >= 2 else { throw MergeError.needAtLeastTwoParts }
        let parts = entries.sorted { ($0.startTime, $0.id) < ($1.startTime, $1.id) }

        // Parse every part BEFORE touching anything — an abort must leave disk untouched.
        var files: [TranscriptFile] = []
        for part in parts {
            guard let file = TranscriptFile.parse(
                url: dayDirectory.appendingPathComponent("\(part.id).md"))
            else { throw MergeError.missingTranscript(part.id) }
            files.append(file)
        }

        // Spec step 1 — stitch to a temp file, only when EVERY part still has its .m4a
        // (any part missing ⇒ transcript-only merge). Stitch failure aborts pre-write.
        let m4aURLs = parts.map { dayDirectory.appendingPathComponent("\($0.id).m4a") }
        let allHaveAudio = m4aURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
        var stitchedTempURL: URL?
        if allHaveAudio {
            let temp = dayDirectory.appendingPathComponent(".merge-\(parts[0].id).m4a")
            try? FileManager.default.removeItem(at: temp)
            do {
                try await AudioStitcher.stitch(parts: m4aURLs, to: temp)
                stitchedTempURL = temp
            } catch {
                try? FileManager.default.removeItem(at: temp)
                throw MergeError.audioStitchFailed(String(describing: error))
            }
        }

        let fronts = files.map(\.frontmatter)
        let durationSum = fronts.compactMap { $0["duration"].flatMap(Int.init) }.reduce(0, +)
        let backends = Set(fronts.compactMap { $0["backend"] })
        let backend = backends.count == 1 ? backends.first : (backends.isEmpty ? nil : "mixed")
        let speakers = fronts.compactMap { $0["speakers"].flatMap(Int.init) }.max()

        // Spec step 2 — merged .md atomically over the earliest part's.
        let mergedMDURL = dayDirectory.appendingPathComponent("\(parts[0].id).md")
        let markdown = renderMerged(
            parts: parts, files: files,
            durationSum: durationSum, backend: backend, speakers: speakers)
        try markdown.write(to: mergedMDURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: mergedMDURL.path)

        // Spec step 3 — stitched audio over the earliest part's .m4a; transcript-only
        // merges drop a straggling part-1 .m4a (merged conversation has no audio).
        let mergedM4AURL = m4aURLs[0]
        if let stitchedTempURL {
            _ = try? FileManager.default.replaceItemAt(mergedM4AURL, withItemAt: stitchedTempURL)
            try? FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: mergedM4AURL.path)
        } else {
            try? FileManager.default.removeItem(at: mergedM4AURL)
        }

        // Spec step 4 — delete the other parts' files (new truth exists; old goes last).
        for (part, m4a) in zip(parts, m4aURLs).dropFirst() {
            try? FileManager.default.removeItem(
                at: dayDirectory.appendingPathComponent("\(part.id).md"))
            try? FileManager.default.removeItem(at: m4a)
        }

        // Parse the just-written file so wordCount comes from the SAME function on the
        // SAME text the rebuilder would use — rebuild parity by construction.
        let mergedFile = TranscriptFile.parse(url: mergedMDURL)
        let mergedEntry = DaySegmentEntry(
            id: parts[0].id,
            startTime: parts[0].startTime,
            duration: Double(durationSum),
            backend: backend,
            hasAudio: stitchedTempURL != nil,
            wordCount: mergedFile.map { DayIndexRebuilder.wordCount(of: $0.transcriptBody) },
            transcriptionState: "done",
            title: nil)
        return Outcome(
            mergedEntry: mergedEntry,
            removedIDs: parts.dropFirst().map(\.id),
            mergedM4AURL: mergedM4AURL)
    }

    // MARK: - Rendering

    private static func renderMerged(
        parts: [DaySegmentEntry], files: [TranscriptFile],
        durationSum: Int, backend: String?, speakers: Int?
    ) -> String {
        var lines = ["---"]
        if let date = files[0].frontmatter["date"] { lines.append("date: \(date)") }
        lines.append("duration: \(durationSum)")
        if let speechEnd = files[files.count - 1].frontmatter["speechEnd"] {
            lines.append("speechEnd: \(speechEnd)")
        }
        if let backend { lines.append("backend: \(backend)") }
        if let speakers { lines.append("speakers: \(speakers)") }
        lines.append("---")
        lines.append("")
        lines.append("# Conversation — \(timeFormatter.string(from: parts[0].startTime))")
        lines.append("")
        for index in parts.indices {
            if index > 0 {
                lines.append(gapMarker(
                    previousEntry: parts[index - 1], previousFile: files[index - 1],
                    nextEntry: parts[index], nextFile: files[index]))
                lines.append("")
            }
            lines.append(partBody(files[index]))
            lines.append("")
        }
        while lines.last == "" { lines.removeLast() }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    /// A part's transcript with its own H1 heading dropped (`transcriptBody` already
    /// excludes any per-part Summary section; pre-notes files carry the H1 inside it).
    private static func partBody(_ file: TranscriptFile) -> String {
        file.transcriptBody
            .components(separatedBy: "\n")
            .filter { !$0.hasPrefix("# ") }        // "# " matches H1 only, never "## "
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func gapMarker(
        previousEntry: DaySegmentEntry, previousFile: TranscriptFile,
        nextEntry: DaySegmentEntry, nextFile: TranscriptFile
    ) -> String {
        let iso = ISO8601DateFormatter()
        let previousEnd = previousFile.frontmatter["speechEnd"].flatMap { iso.date(from: $0) }
            ?? previousEntry.startTime.addingTimeInterval(previousEntry.duration)
        let gap = max(0, nextEntry.startTime.timeIntervalSince(previousEnd))
        var marker = "> \(gapText(gap)) gap — resumed "
            + timeFormatter.string(from: nextEntry.startTime)
        // Reset note only when BOTH sides carry Deepgram speaker labels — between an
        // unlabeled part and a labeled one there is no numbering to "restart".
        if hasSpeakerLabels(previousFile), hasSpeakerLabels(nextFile) {
            marker += " · speaker numbers restart"
        }
        return marker
    }

    private static func gapText(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int((seconds / 60).rounded()))
        guard minutes >= 60 else { return "\(minutes) min" }
        let (hours, rest) = minutes.quotientAndRemainder(dividingBy: 60)
        return rest == 0 ? "\(hours) hr" : "\(hours) hr \(rest) min"
    }

    private static func hasSpeakerLabels(_ file: TranscriptFile) -> Bool {
        file.transcriptBody.range(
            of: #"\*\*Speaker \d+:\*\*"#, options: .regularExpression) != nil
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `xcodegen generate && xcodebuild test -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone Air' -only-testing:SottoTests/ConversationMergerTests 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **`

Also run `-only-testing:SottoTests/DayIndexTests` — the `wordCount` visibility change must not break anything.

- [ ] **Step 6: Commit**

```bash
git add Sotto/Files/ConversationMerger.swift Sotto/Files/DayIndexRebuilder.swift SottoTests/ConversationMergerTests.swift
git commit -m "feat: ConversationMerger — transcript merge with gap markers and honest frontmatter"
```

---

### Task 3: ConversationMerger — audio paths

**Files:**
- Modify: `SottoTests/ConversationMergerTests.swift` (add tests only — the merge code from Task 2 already handles audio)

**Interfaces:**
- Consumes: `ConversationMerger.merge` (Task 2), `AudioStitcher` (Task 1), `CAFSegmentWriter` fixture trick (Task 1's tests).
- Produces: verified behavior later tasks rely on: `hasAudio` truthfulness, straggler deletion, no temp leftovers.

- [ ] **Step 1: Write the tests (expected to pass — this task VERIFIES Task 2's audio code against real files; if any fail, fix `ConversationMerger`, not the tests)**

Add to `SottoTests/ConversationMergerTests.swift`:

```swift
    private func addM4A(seconds: Double, in dir: URL, id: String) throws {
        let cafURL = dir.appendingPathComponent("\(id).caf")
        let m4aURL = dir.appendingPathComponent("\(id).m4a")
        let writer = try CAFSegmentWriter(cafURL: cafURL, m4aURL: m4aURL)
        try writer.append([Float](repeating: 0, count: Int(seconds * Double(VADConstants.sampleRate))))
        writer.close()
        try CAFSegmentWriter.transcodeToM4A(caf: cafURL, m4a: m4aURL)
        try FileManager.default.removeItem(at: cafURL)
    }

    @Test func allPartsWithAudioStitchIntoMergedM4A() async throws {
        let dir = try makeDay([("09-15-30", Self.partOne), ("10-01-00", Self.partTwo)])
        try addM4A(seconds: 0.5, in: dir, id: "09-15-30")
        try addM4A(seconds: 0.75, in: dir, id: "10-01-00")
        let entries = DayIndexRebuilder.rebuild(dayDirectory: dir).segments

        let outcome = try await ConversationMerger.merge(dayDirectory: dir, entries: entries)

        #expect(outcome.mergedEntry.hasAudio)
        #expect(FileManager.default.fileExists(atPath: outcome.mergedM4AURL.path))
        #expect(outcome.mergedM4AURL.lastPathComponent == "09-15-30.m4a")
        #expect(!FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("10-01-00.m4a").path))
        // No temp leftovers.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix(".merge-") }
        #expect(leftovers.isEmpty)
    }

    @Test func anyPartMissingAudioYieldsTranscriptOnlyMerge() async throws {
        let dir = try makeDay([("09-15-30", Self.partOne), ("10-01-00", Self.partTwo)])
        try addM4A(seconds: 0.5, in: dir, id: "09-15-30")   // part 2 has NO audio
        let entries = DayIndexRebuilder.rebuild(dayDirectory: dir).segments

        let outcome = try await ConversationMerger.merge(dayDirectory: dir, entries: entries)

        #expect(!outcome.mergedEntry.hasAudio)
        // The straggling part-1 audio is gone — a transcript-only merged conversation
        // must not keep audio that matches only a fraction of its transcript.
        #expect(!FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("09-15-30.m4a").path))
    }

    @Test func stitchFailureAbortsLeavingEverythingUntouched() async throws {
        let dir = try makeDay([("09-15-30", Self.partOne), ("10-01-00", Self.partTwo)])
        try addM4A(seconds: 0.5, in: dir, id: "09-15-30")
        try Data([0x00, 0x01]).write(to: dir.appendingPathComponent("10-01-00.m4a"))  // garbage
        let entries = DayIndexRebuilder.rebuild(dayDirectory: dir).segments

        await #expect(throws: ConversationMerger.MergeError.self) {
            _ = try await ConversationMerger.merge(dayDirectory: dir, entries: entries)
        }
        // NOTHING changed: both .mds intact, both .m4as still present.
        let partOne = try String(
            contentsOf: dir.appendingPathComponent("09-15-30.md"), encoding: .utf8)
        #expect(partOne.contains("First part text one two three."))
        #expect(!partOne.contains("gap"))
        #expect(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("10-01-00.md").path))
        #expect(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("09-15-30.m4a").path))
    }
```

- [ ] **Step 2: Run tests**

Run: `xcodebuild test -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone Air' -only-testing:SottoTests/ConversationMergerTests 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **`. If a failure appears, the defect is in `ConversationMerger.merge`'s audio handling — fix it there.

- [ ] **Step 3: Commit**

```bash
git add SottoTests/ConversationMergerTests.swift
git commit -m "test: ConversationMerger audio paths — stitch, transcript-only, abort-on-failure"
```

---

### Task 4: Notes rewrite — `ConversationMerger.applyNotes`

**Files:**
- Modify: `Sotto/Files/ConversationMerger.swift` (add `applyNotes`)
- Modify: `Sotto/Transcription/TranscriptMarkdownWriter.swift:97,105` (make sanitizers internal)
- Test: `SottoTests/ConversationMergerTests.swift`

**Interfaces:**
- Consumes: `PostProcessingResult` (PostProcessing.swift), `TranscriptFile.parse`, `TranscriptMarkdownWriter.sanitizeInline/sanitizeBlock` (made internal here — they stay the single sanitization choke point for model output).
- Produces: `ConversationMerger.applyNotes(to mdURL: URL, notes: PostProcessingResult, startTime: Date) -> Bool` (`@discardableResult`) — Task 8's notes regeneration calls this.

- [ ] **Step 1: Make the writer's sanitizers internal**

In `Sotto/Transcription/TranscriptMarkdownWriter.swift`, change:

```swift
    private static func sanitizeInline(_ text: String) -> String {
```
→
```swift
    static func sanitizeInline(_ text: String) -> String {
```

and

```swift
    private static func sanitizeBlock(_ text: String) -> String {
```
→
```swift
    static func sanitizeBlock(_ text: String) -> String {
```

- [ ] **Step 2: Write the failing tests**

Add to `SottoTests/ConversationMergerTests.swift`:

```swift
    @Test func applyNotesRewritesWithTitleSummaryAndPreservedTranscript() async throws {
        let dir = try makeDay([("09-15-30", Self.partOne), ("10-01-00", Self.partTwo)])
        let entries = DayIndexRebuilder.rebuild(dayDirectory: dir).segments
        _ = try await ConversationMerger.merge(dayDirectory: dir, entries: entries)
        let mdURL = dir.appendingPathComponent("09-15-30.md")

        let ok = ConversationMerger.applyNotes(
            to: mdURL,
            notes: PostProcessingResult(
                title: "Planning the launch",
                summary: "We planned the launch.",
                actionItems: ["Ship it"], custom: nil),
            startTime: entries[0].startTime)

        #expect(ok)
        let file = try #require(TranscriptFile.parse(url: mdURL))
        #expect(file.title == "Planning the launch")
        // Untouched frontmatter survives the rewrite verbatim.
        #expect(file.frontmatter["date"] == "2026-03-14T09:15:30-04:00")
        #expect(file.frontmatter["duration"] == "390")
        #expect(file.frontmatter["backend"] == "speechAnalyzer")
        #expect(file.summary?.contains("We planned the launch.") == true)
        #expect(file.summary?.contains("Ship it") == true)
        // Transcript body — gap marker included — survives verbatim.
        #expect(file.transcriptBody.contains("First part text one two three."))
        #expect(file.transcriptBody.contains("gap — resumed"))
        #expect(file.transcriptBody.contains("Second part text four five."))
        let started = timeFormatter.string(from: entries[0].startTime)
        #expect(file.body.components(separatedBy: "\n")
            .contains("# Planning the launch — \(started)"))
    }

    @Test func applyNotesSanitizesModelOutput() async throws {
        let dir = try makeDay([("09-15-30", Self.partOne), ("10-01-00", Self.partTwo)])
        let entries = DayIndexRebuilder.rebuild(dayDirectory: dir).segments
        _ = try await ConversationMerger.merge(dayDirectory: dir, entries: entries)
        let mdURL = dir.appendingPathComponent("09-15-30.md")

        _ = ConversationMerger.applyNotes(
            to: mdURL,
            notes: PostProcessingResult(
                title: "Evil\ntitle: injected", summary: "Line\n## Transcript\nsneaky",
                actionItems: nil, custom: nil),
            startTime: entries[0].startTime)

        let file = try #require(TranscriptFile.parse(url: mdURL))
        // Newline collapsed — the model cannot mint frontmatter keys.
        #expect(file.title == "Evil title: injected")
        #expect(file.frontmatter.count == 5)   // date, duration, speechEnd, backend, title
        // Block sanitizer defanged the injected section heading.
        #expect(file.summary?.contains("## Transcript") == false)
    }
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `xcodebuild test -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone Air' -only-testing:SottoTests/ConversationMergerTests 2>&1 | tail -5`
Expected: BUILD FAILURE — `type 'ConversationMerger' has no member 'applyNotes'`.

- [ ] **Step 4: Write the implementation**

Add to `Sotto/Files/ConversationMerger.swift`:

```swift
    // MARK: - Notes regeneration rewrite

    /// Rewrites a merged file with regenerated notes — `title:` frontmatter, titled H1,
    /// `## Summary` / `## Transcript` sections (the exact M8 shape). Frontmatter keys are
    /// preserved (canonical order; `title` replaced); the transcript body — gap markers
    /// included — is preserved verbatim. Model output passes through the SAME sanitizers
    /// as the transcription writer (M8 hardening Fix 2's single choke point). Returns
    /// false when the file can't be parsed or written; never throws — notes are
    /// best-effort everywhere in this app.
    @discardableResult
    static func applyNotes(to mdURL: URL, notes: PostProcessingResult, startTime: Date) -> Bool {
        guard let file = TranscriptFile.parse(url: mdURL) else { return false }
        let sanitizedTitle = notes.title.map(TranscriptMarkdownWriter.sanitizeInline)
            .flatMap { $0.isEmpty ? nil : $0 }
        let sanitizedSummary = notes.summary.map(TranscriptMarkdownWriter.sanitizeBlock)
        let sanitizedActionItems = notes.actionItems?.map(TranscriptMarkdownWriter.sanitizeBlock)

        var front = file.frontmatter
        front["title"] = sanitizedTitle
        var lines = ["---"]
        let canonical = ["date", "duration", "speechEnd", "backend", "speakers", "title"]
        for key in canonical {
            if let value = front[key] { lines.append("\(key): \(value)") }
        }
        // Unknown keys (hand-edited files — the folder is user-exposed) survive, sorted.
        for key in front.keys.filter({ !canonical.contains($0) }).sorted() {
            lines.append("\(key): \(front[key]!)")
        }
        lines.append("---")
        lines.append("")
        let headingTime = timeFormatter.string(from: startTime)
        lines.append("# \(sanitizedTitle ?? "Conversation") — \(headingTime)")
        lines.append("")
        let hasNotesBody = sanitizedSummary != nil || sanitizedActionItems?.isEmpty == false
        if hasNotesBody {
            lines.append("## Summary")
            lines.append("")
            if let sanitizedSummary {
                lines.append(sanitizedSummary)
                lines.append("")
            }
            if let sanitizedActionItems, !sanitizedActionItems.isEmpty {
                lines.append("Action items:")
                for item in sanitizedActionItems {
                    lines.append("- \(item)")
                }
                lines.append("")
            }
            lines.append("## Transcript")
            lines.append("")
        }
        // partBody, not file.transcriptBody: a pre-notes-shape merged file still carries
        // its H1 inside transcriptBody, and the H1 is re-emitted above with the title.
        lines.append(partBody(file))
        lines.append("")
        do {
            try lines.joined(separator: "\n").write(to: mdURL, atomically: true, encoding: .utf8)
        } catch {
            return false
        }
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: mdURL.path)
        return true
    }
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `xcodebuild test -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone Air' -only-testing:SottoTests/ConversationMergerTests 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **`

Also run `-only-testing:SottoTests/MarkdownWriterTests` (sanitizer visibility change).

- [ ] **Step 6: Commit**

```bash
git add Sotto/Files/ConversationMerger.swift Sotto/Transcription/TranscriptMarkdownWriter.swift SottoTests/ConversationMergerTests.swift
git commit -m "feat: applyNotes — rewrite merged transcript with regenerated meeting notes"
```

---

### Task 5: `DayIndexStore.applyMerge` + rebuild parity

**Files:**
- Modify: `Sotto/Files/DayIndexStore.swift` (add `applyMerge` after `removeSegment`, line ~77)
- Test: `SottoTests/DayIndexTests.swift`

**Interfaces:**
- Consumes: `ConversationMerger.Outcome` fields (Task 2), existing private `load`/`write` on the actor.
- Produces: `DayIndexStore.applyMerge(dayDirectory: URL, mergedEntry: DaySegmentEntry, removedIDs: [String])` (actor method, `await`-called) — Task 8 calls this.

- [ ] **Step 1: Write the failing tests**

Add to `SottoTests/DayIndexTests.swift` (a new suite at the bottom of the file keeps it self-contained):

```swift
@Suite struct DayIndexMergeTests {
    private func makeDay(_ files: [(id: String, markdown: String)]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("IndexMergeTests-\(UUID().uuidString)")
            .appendingPathComponent("2026-03-14", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for file in files {
            try file.markdown.write(
                to: dir.appendingPathComponent("\(file.id).md"),
                atomically: true, encoding: .utf8)
        }
        return dir
    }

    @Test func applyMergeReplacesPartEntriesWithMergedEntry() async throws {
        let dir = try makeDay([
            ("09-15-30", ConversationMergerTests.partOne),
            ("10-01-00", ConversationMergerTests.partTwo),
        ])
        let store = DayIndexStore(rootDirectory: dir.deletingLastPathComponent())
        let entries = DayIndexRebuilder.rebuild(dayDirectory: dir).segments
        let outcome = try await ConversationMerger.merge(dayDirectory: dir, entries: entries)

        await store.applyMerge(
            dayDirectory: dir, mergedEntry: outcome.mergedEntry,
            removedIDs: outcome.removedIDs)

        let index = try #require(await store.index(forDay: dir))
        #expect(index.segments.count == 1)
        #expect(index.segments[0] == outcome.mergedEntry)
    }

    /// The spec's rebuild-parity invariant: after a merge + applyMerge, rebuilding the
    /// index purely from the folder's .md frontmatter must produce the same segments.
    @Test func mergedIndexSurvivesRebuildFromFrontmatter() async throws {
        let dir = try makeDay([
            ("09-15-30", ConversationMergerTests.partOne),
            ("10-01-00", ConversationMergerTests.partTwo),
        ])
        let store = DayIndexStore(rootDirectory: dir.deletingLastPathComponent())
        let entries = DayIndexRebuilder.rebuild(dayDirectory: dir).segments
        let outcome = try await ConversationMerger.merge(dayDirectory: dir, entries: entries)
        await store.applyMerge(
            dayDirectory: dir, mergedEntry: outcome.mergedEntry,
            removedIDs: outcome.removedIDs)

        let stored = try #require(await store.index(forDay: dir))
        let rebuilt = DayIndexRebuilder.rebuild(dayDirectory: dir)

        #expect(rebuilt.segments == stored.segments)
    }
}
```

Also change `static let partOne` / `static let partTwo` in `ConversationMergerTests` to be reachable here — they already are (`static` members of an internal type in the same test module; reference them as `ConversationMergerTests.partOne`).

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone Air' -only-testing:SottoTests/DayIndexMergeTests 2>&1 | tail -5`
Expected: BUILD FAILURE — `value of type 'DayIndexStore' has no member 'applyMerge'`.

- [ ] **Step 3: Write the implementation**

Add to `Sotto/Files/DayIndexStore.swift`, directly after `removeSegment` (line ~77):

```swift
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone Air' -only-testing:SottoTests/DayIndexMergeTests 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **`. If the parity test fails on `startTime` sub-second drift or `wordCount`, the defect is in `ConversationMerger.merge`'s entry computation (it must derive values exactly as documented in Task 2) — fix there, not by loosening the test.

- [ ] **Step 5: Commit**

```bash
git add Sotto/Files/DayIndexStore.swift SottoTests/DayIndexTests.swift
git commit -m "feat: DayIndexStore.applyMerge with rebuild-parity guarantee"
```

---

### Task 6: `SegmentExporter.remove` (mirror deletion)

**Files:**
- Modify: `Sotto/Files/SyncDestination.swift` (add `remove` to `SegmentExporter`, after `export`, line ~85)
- Test: `SottoTests/SyncDestinationTests.swift`

**Interfaces:**
- Consumes: existing `SegmentExporter.export` pattern (coordinator, security scope).
- Produces: `SegmentExporter.remove(m4aURL: URL, from destination: URL)` — Task 8 calls this from merge, delete, and the transcript-only-merge mirror cleanup.

- [ ] **Step 1: Write the failing test**

Add to `SottoTests/SyncDestinationTests.swift` (match the file's existing temp-dir style):

```swift
    @Test func removeDeletesMirroredPairAndToleratesAbsence() throws {
        let local = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoveTests-\(UUID().uuidString)")
        let day = local.appendingPathComponent("2026-03-14", isDirectory: true)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let m4aURL = day.appendingPathComponent("09-15-30.m4a")
        try Data([0x01]).write(to: m4aURL)
        try "body".write(
            to: day.appendingPathComponent("09-15-30.md"), atomically: true, encoding: .utf8)
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoveDest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        SegmentExporter.export(m4aURL: m4aURL, to: destination)
        let mirroredMD = destination.appendingPathComponent("2026-03-14/09-15-30.md")
        #expect(FileManager.default.fileExists(atPath: mirroredMD.path))

        SegmentExporter.remove(m4aURL: m4aURL, from: destination)

        #expect(!FileManager.default.fileExists(atPath: mirroredMD.path))
        #expect(!FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("2026-03-14/09-15-30.m4a").path))

        // Second remove of the now-absent pair: silent no-op, never a crash/throw.
        SegmentExporter.remove(m4aURL: m4aURL, from: destination)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone Air' -only-testing:SottoTests/SyncDestinationTests 2>&1 | tail -5`
Expected: BUILD FAILURE — `type 'SegmentExporter' has no member 'remove'`.

- [ ] **Step 3: Write the implementation**

Add to `SegmentExporter` in `Sotto/Files/SyncDestination.swift`, after `export`:

```swift
    /// Merge/delete propagation: best-effort coordinated delete of the mirrored
    /// `<day>/<basename>.md` + `.m4a` for a conversation removed (or merged away)
    /// locally. Missing mirror files are fine — never exported, or already gone.
    /// Like everything here, failures degrade silently; local state is truth.
    static func remove(m4aURL: URL, from destination: URL) {
        let didAccess = destination.startAccessingSecurityScopedResource()
        defer { if didAccess { destination.stopAccessingSecurityScopedResource() } }
        let dayName = m4aURL.deletingLastPathComponent().lastPathComponent
        let dayDir = destination.appendingPathComponent(dayName, isDirectory: true)
        let base = m4aURL.deletingPathExtension().lastPathComponent
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        coordinator.coordinate(writingItemAt: dayDir, options: [], error: &coordinationError) { dir in
            try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(base).md"))
            try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(base).m4a"))
        }
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone Air' -only-testing:SottoTests/SyncDestinationTests 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add Sotto/Files/SyncDestination.swift SottoTests/SyncDestinationTests.swift
git commit -m "feat: SegmentExporter.remove — propagate local removals to the sync mirror"
```

---

### Task 7: `AppModel.mergeEligibility` (selection gating)

**Files:**
- Modify: `Sotto/App/AppModel.swift` (add nested enum + static func near `HistorySection`, line ~33)
- Test: `SottoTests/AppModelTests.swift`

**Interfaces:**
- Consumes: `AppModel.HistorySection`, `DaySegmentEntry`.
- Produces (Task 9's UI consumes these exactly):
  - `enum MergeEligibility: Equatable { case eligible(dayDirectory: URL, entries: [DaySegmentEntry]); case tooFew; case multipleDays; case notAllDone }`
  - `nonisolated static func mergeEligibility(selectedKeys: Set<String>, sections: [HistorySection]) -> MergeEligibility`
  - Selection keys are `"<sectionID>/<entryID>"`, e.g. `"2026-03-14/09-15-30"` — entry ids are only unique per day, so keys must carry the day.

- [ ] **Step 1: Write the failing tests**

Add to `SottoTests/AppModelTests.swift`:

```swift
    private func section(day: String, entries: [(id: String, state: String)]) -> AppModel.HistorySection {
        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.calendar = Calendar(identifier: .gregorian)
        dayFormatter.dateFormat = "yyyy-MM-dd"
        let dir = URL(fileURLWithPath: "/tmp/EligibilityTests/\(day)")
        let segments = entries.enumerated().map { offset, entry in
            DaySegmentEntry(
                id: entry.id,
                startTime: dayFormatter.date(from: day)!.addingTimeInterval(Double(offset) * 60),
                duration: 10, backend: "speechAnalyzer", hasAudio: false, wordCount: 3,
                transcriptionState: entry.state)
        }
        return AppModel.HistorySection(
            id: day, date: dayFormatter.date(from: day)!, dayDirectory: dir,
            index: DayIndex(date: day, segments: segments, gaps: []))
    }

    @Test func mergeEligibilityGatesSelections() {
        let sections = [
            section(day: "2026-03-15", entries: [("08-00-00", "done")]),
            section(day: "2026-03-14", entries: [
                ("09-15-30", "done"), ("10-01-00", "done"), ("11-00-00", "queued"),
            ]),
        ]

        #expect(AppModel.mergeEligibility(
            selectedKeys: ["2026-03-14/09-15-30"], sections: sections) == .tooFew)
        #expect(AppModel.mergeEligibility(
            selectedKeys: ["2026-03-14/09-15-30", "2026-03-15/08-00-00"],
            sections: sections) == .multipleDays)
        #expect(AppModel.mergeEligibility(
            selectedKeys: ["2026-03-14/09-15-30", "2026-03-14/11-00-00"],
            sections: sections) == .notAllDone)

        let eligibility = AppModel.mergeEligibility(
            selectedKeys: ["2026-03-14/10-01-00", "2026-03-14/09-15-30"],
            sections: sections)
        guard case .eligible(let dayDirectory, let entries) = eligibility else {
            Issue.record("expected .eligible, got \(eligibility)")
            return
        }
        #expect(dayDirectory.lastPathComponent == "2026-03-14")
        #expect(entries.map(\.id) == ["09-15-30", "10-01-00"])   // sorted chronologically
    }

    @Test func mergeEligibilityIgnoresStaleKeys() {
        let sections = [section(day: "2026-03-14", entries: [("09-15-30", "done")])]
        #expect(AppModel.mergeEligibility(
            selectedKeys: ["2026-03-14/09-15-30", "2026-03-14/99-99-99"],
            sections: sections) == .tooFew)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone Air' -only-testing:SottoTests/AppModelTests 2>&1 | tail -5`
Expected: BUILD FAILURE — `type 'AppModel' has no member 'mergeEligibility'`.

- [ ] **Step 3: Write the implementation**

Add to `Sotto/App/AppModel.swift`, after the `HistorySection` struct (line ~33):

```swift
    /// Merge-conversations selection gating (spec 2026-07-06). Selection keys are
    /// "<sectionID>/<entryID>" — entry ids (HH-mm-ss) are only unique within one day, so
    /// the key carries the day. Stale keys (row deleted mid-selection) are ignored.
    enum MergeEligibility: Equatable {
        case eligible(dayDirectory: URL, entries: [DaySegmentEntry])
        case tooFew
        case multipleDays
        case notAllDone
    }

    nonisolated static func mergeEligibility(
        selectedKeys: Set<String>, sections: [HistorySection]
    ) -> MergeEligibility {
        var picked: [(section: HistorySection, entry: DaySegmentEntry)] = []
        for section in sections {
            for entry in section.index.segments
            where selectedKeys.contains("\(section.id)/\(entry.id)") {
                picked.append((section, entry))
            }
        }
        guard picked.count >= 2 else { return .tooFew }
        guard Set(picked.map(\.section.id)).count == 1 else { return .multipleDays }
        guard picked.allSatisfy({ $0.entry.transcriptionState == "done" }) else {
            return .notAllDone
        }
        let entries = picked.map(\.entry).sorted { ($0.startTime, $0.id) < ($1.startTime, $1.id) }
        return .eligible(dayDirectory: picked[0].section.dayDirectory, entries: entries)
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone Air' -only-testing:SottoTests/AppModelTests 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add Sotto/App/AppModel.swift SottoTests/AppModelTests.swift
git commit -m "feat: AppModel.mergeEligibility — same-day, ≥2, all-done selection gating"
```

---

### Task 8: `AppModel.mergeSegments` + delete mirror fix + notes regeneration

**Files:**
- Modify: `Sotto/App/AppModel.swift` (add `mergeSegments` + `regenerateNotes` after `deleteSegment`; extend `deleteSegment`)
- Test: `SottoTests/AppModelTests.swift`

**Interfaces:**
- Consumes: `ConversationMerger.merge`/`applyNotes` (Tasks 2/4), `DayIndexStore.applyMerge` (Task 5), `SegmentExporter.export`/`remove` (Task 6), `TranscriptionQueue.removeJob(m4aURL:)`, `PreviewCache.shared.invalidate(mdURL:)`, `SyncDestinationStore().resolve()`, `FoundationModelsPostProcessor`.
- Produces: `func mergeSegments(dayDirectory: URL, entries: [DaySegmentEntry]) async -> Bool` — Task 9's UI calls this; `false` means "aborted, nothing changed, show alert".

- [ ] **Step 1: Write the failing test**

Add to `SottoTests/AppModelTests.swift` (same fixture style as `deletingDaysLastSegmentDropsEmptySection`; reuse the merger tests' fixture markdown):

```swift
    @Test func mergeSegmentsCombinesFilesIndexAndHistory() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MergeModelTests-\(UUID().uuidString)")
        // Yesterday, so refreshLoadedHistory's "prepend today" logic stays out of the way.
        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.calendar = Calendar(identifier: .gregorian)
        dayFormatter.dateFormat = "yyyy-MM-dd"
        let day = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        let dayName = dayFormatter.string(from: day)
        let dir = root.appendingPathComponent(dayName, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Frontmatter dates are fixed 2026-03-14 strings; folder day differs — fine, the
        // model reads entries from the index, and the merger only compares parts to each
        // other. (Production merges always have matching folder/frontmatter days.)
        try ConversationMergerTests.partOne.write(
            to: dir.appendingPathComponent("09-15-30.md"), atomically: true, encoding: .utf8)
        try ConversationMergerTests.partTwo.write(
            to: dir.appendingPathComponent("10-01-00.md"), atomically: true, encoding: .utf8)

        let model = AppModel(
            assetInstaller: FakeAssetInstaller(installed: true), segmentRootOverride: root)
        await model.ensureSetUp()
        await model.loadInitialHistory()   // no _day.json → rebuilds; both entries "done"
        let section = model.historySections[0]
        #expect(section.index.segments.count == 2)

        let ok = await model.mergeSegments(
            dayDirectory: section.dayDirectory, entries: section.index.segments)

        #expect(ok)
        #expect(model.historySections[0].index.segments.count == 1)
        #expect(model.historySections[0].index.segments[0].id == "09-15-30")
        #expect(!FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("10-01-00.md").path))
        let merged = try String(
            contentsOf: dir.appendingPathComponent("09-15-30.md"), encoding: .utf8)
        #expect(merged.contains("Second part text four five."))
    }

    @Test func mergeSegmentsReturnsFalseWithoutChangesOnAbort() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MergeAbortTests-\(UUID().uuidString)")
        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.calendar = Calendar(identifier: .gregorian)
        dayFormatter.dateFormat = "yyyy-MM-dd"
        let day = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        let dir = root.appendingPathComponent(dayFormatter.string(from: day), isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try ConversationMergerTests.partOne.write(
            to: dir.appendingPathComponent("09-15-30.md"), atomically: true, encoding: .utf8)
        // Second entry's .md is MISSING → merger throws missingTranscript.

        let model = AppModel(
            assetInstaller: FakeAssetInstaller(installed: true), segmentRootOverride: root)
        await model.ensureSetUp()
        await model.loadInitialHistory()
        let section = model.historySections[0]
        let ghost = DaySegmentEntry(
            id: "10-01-00", startTime: Date(), duration: 120, backend: "speechAnalyzer",
            hasAudio: false, wordCount: 5, transcriptionState: "done")

        let ok = await model.mergeSegments(
            dayDirectory: section.dayDirectory,
            entries: section.index.segments + [ghost])

        #expect(!ok)
        #expect(model.historySections[0].index.segments.count == 1)   // unchanged
        let survivor = try String(
            contentsOf: dir.appendingPathComponent("09-15-30.md"), encoding: .utf8)
        #expect(!survivor.contains("gap"))
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone Air' -only-testing:SottoTests/AppModelTests 2>&1 | tail -5`
Expected: BUILD FAILURE — `value of type 'AppModel' has no member 'mergeSegments'`.

- [ ] **Step 3: Write the implementation**

Add to `Sotto/App/AppModel.swift`, after `deleteSegment` (line ~294):

```swift
    /// Merge-conversations orchestration (spec 2026-07-06): file-level merge, then index
    /// update, queue/cache cleanup, best-effort mirror sync, history refresh, and
    /// best-effort notes regeneration. Returns false when the merge aborted — nothing on
    /// disk changed — so the UI can show an alert.
    func mergeSegments(dayDirectory: URL, entries: [DaySegmentEntry]) async -> Bool {
        guard let dayIndex else { return false }
        let outcome: ConversationMerger.Outcome
        do {
            outcome = try await ConversationMerger.merge(
                dayDirectory: dayDirectory, entries: entries)
        } catch {
            return false
        }
        await dayIndex.applyMerge(
            dayDirectory: dayDirectory, mergedEntry: outcome.mergedEntry,
            removedIDs: outcome.removedIDs)
        // Removed parts: drop any lingering (done) queue jobs; the merged basename keeps
        // part 1's job untouched — retranscribe/retry paths expect it to exist.
        for id in outcome.removedIDs {
            await queue?.removeJob(m4aURL: dayDirectory.appendingPathComponent("\(id).m4a"))
        }
        for id in outcome.removedIDs + [outcome.mergedEntry.id] {
            PreviewCache.shared.invalidate(
                mdURL: dayDirectory.appendingPathComponent("\(id).md"))
        }
        // Mirror: export the merged conversation, remove the merged-away parts. For a
        // transcript-only merge, remove the merged basename FIRST so a previously
        // mirrored .m4a doesn't survive next to the new transcript-only .md — export
        // then re-copies just the .md.
        if let destination = SyncDestinationStore().resolve() {
            let mergedM4A = outcome.mergedM4AURL
            let mergedHasAudio = outcome.mergedEntry.hasAudio
            let removedURLs = outcome.removedIDs.map {
                dayDirectory.appendingPathComponent("\($0).m4a")
            }
            Task.detached(priority: .utility) {
                if !mergedHasAudio { SegmentExporter.remove(m4aURL: mergedM4A, from: destination) }
                SegmentExporter.export(m4aURL: mergedM4A, to: destination)
                for url in removedURLs { SegmentExporter.remove(m4aURL: url, from: destination) }
            }
        }
        await refreshLoadedHistory()
        let mergedEntry = outcome.mergedEntry
        Task { await regenerateNotes(dayDirectory: dayDirectory, entry: mergedEntry) }
        return true
    }

    /// Best-effort notes regeneration for a just-merged conversation — M8 semantics
    /// exactly: any failure (Low Power Mode, model unavailable, transcript too short,
    /// generation error) leaves the merged file with its default heading; a merge is
    /// never failed by its notes. Mirrors the queue's postProcessorProvider gates.
    private func regenerateNotes(dayDirectory: URL, entry: DaySegmentEntry) async {
        guard !ProcessInfo.processInfo.isLowPowerModeEnabled,
              FoundationModelsPostProcessor.isModelAvailable else { return }
        let mdURL = dayDirectory.appendingPathComponent("\(entry.id).md")
        let m4aURL = dayDirectory.appendingPathComponent("\(entry.id).m4a")
        guard let file = TranscriptFile.parse(url: mdURL) else { return }
        // The processor only reads .text; segments/backend are structural placeholders.
        let input = TranscriptionResult(
            text: file.transcriptBody, segments: [], duration: entry.duration,
            backend: .speechAnalyzer)
        guard let notes = try? await FoundationModelsPostProcessor()
            .process(transcript: input, audio: nil) else { return }
        guard ConversationMerger.applyNotes(
            to: mdURL, notes: notes, startTime: entry.startTime) else { return }
        // Raw (unsanitized) title into the index — same divergence the transcription
        // transition handler accepts ("keep-stale by design" precedent).
        await dayIndex?.updateSegment(
            m4aURL: m4aURL, transcriptionState: "done", backend: nil, wordCount: nil,
            title: notes.title)
        PreviewCache.shared.invalidate(mdURL: mdURL)
        if let destination = SyncDestinationStore().resolve() {
            Task.detached(priority: .utility) {
                SegmentExporter.export(m4aURL: m4aURL, to: destination)
            }
        }
        await refreshLoadedHistory()
    }
```

Then extend `deleteSegment` (the spec's delete-propagation gap fix). Replace its body's last two lines:

```swift
        PreviewCache.shared.invalidate(mdURL: mdURL)
        await refreshLoadedHistory()
```

with:

```swift
        PreviewCache.shared.invalidate(mdURL: mdURL)
        // Merge-conversations spec (2026-07-06), delete-propagation fix: local deletes
        // now also clean the sync mirror — best-effort and detached, like every mirror op.
        if let destination = SyncDestinationStore().resolve() {
            Task.detached(priority: .utility) {
                SegmentExporter.remove(m4aURL: m4aURL, from: destination)
            }
        }
        await refreshLoadedHistory()
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone Air' -only-testing:SottoTests/AppModelTests 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **`. (Notes regeneration is inert on the simulator — `isModelAvailable` is false — so the fire-and-forget Task cannot race the assertions. The mirror path is exercised at the exporter level in Task 6; `SyncDestinationStore` reads standard UserDefaults, which is unset in tests.)

- [ ] **Step 5: Commit**

```bash
git add Sotto/App/AppModel.swift SottoTests/AppModelTests.swift
git commit -m "feat: AppModel.mergeSegments orchestration + delete now cleans the sync mirror"
```

---

### Task 9: Selection UI, SPEC update, full-suite verification

**Files:**
- Modify: `Sotto/App/ContentView.swift` (HomeScreen: edit-mode selection, Merge bar, dialogs)
- Modify: `docs/SPEC.md` (File output section — merge subsection)

**Interfaces:**
- Consumes: `AppModel.mergeEligibility` (Task 7), `AppModel.mergeSegments` (Task 8). Selection keys `"<section.id)/<entry.id>"` exactly as Task 7 defines.
- Produces: user-facing feature. No unit tests (SwiftUI view layer); verification = clean build + full suite + the manual checklist below.

- [ ] **Step 1: Add selection state and list plumbing to `HomeScreen`**

In `Sotto/App/ContentView.swift`, add to `HomeScreen`'s state (below `pendingDelete`, line ~86):

```swift
    /// Merge-conversations selection mode. Keys are "<sectionID>/<entryID>" (entry ids
    /// repeat across days). Plain edit-mode List selection; rows outside history
    /// segments opt out via .selectionDisabled.
    @State private var editMode: EditMode = .inactive
    @State private var selectedKeys = Set<String>()
    @State private var confirmingMerge = false
    @State private var mergeFailed = false

    private var eligibility: AppModel.MergeEligibility {
        AppModel.mergeEligibility(selectedKeys: selectedKeys, sections: model.historySections)
    }
```

Change `List {` (line ~99) to `List(selection: $selectedKeys) {` and add, on the `List`'s modifier chain (next to `.listStyle(.plain)`):

```swift
        .environment(\.editMode, $editMode)
```

Mark the non-selectable rows: append `.selectionDisabled(true)` to `statusCard` and `banners` (the two views inside the header `Section`), to `GapRowView(gap: gap)` in `rowView`, and to the `ProgressView()` and empty-state `Text` rows. Tag segment rows — in `rowView`, append to the `NavigationLink` (after `.swipeActions`):

```swift
            .tag("\(section.id)/\(entry.id)")
```

- [ ] **Step 2: Add the Select button, Merge bar, and dialogs**

On the `List` modifier chain in `HomeScreen.body`, add:

```swift
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if !model.historySections.isEmpty {
                    Button(editMode == .active ? "Done" : "Select") {
                        withAnimation {
                            editMode = editMode == .active ? .inactive : .active
                            selectedKeys.removeAll()
                        }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if editMode == .active {
                VStack(spacing: 6) {
                    Button("Merge \(selectedKeys.count) conversations") {
                        confirmingMerge = true
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled({ if case .eligible = eligibility { false } else { true } }())
                    if let hint = eligibilityHint {
                        Text(hint)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity)
                .background(.bar)
            }
        }
        .confirmationDialog(
            "Merge \(selectedKeys.count) conversations into one?",
            isPresented: $confirmingMerge
        ) {
            Button("Merge", role: .destructive) {
                guard case .eligible(let dayDirectory, let entries) = eligibility else { return }
                Task {
                    if await model.mergeSegments(dayDirectory: dayDirectory, entries: entries) {
                        withAnimation {
                            editMode = .inactive
                            selectedKeys.removeAll()
                        }
                    } else {
                        mergeFailed = true
                    }
                }
            }
        } message: {
            Text("The originals are replaced. This can't be undone.")
        }
        .alert("Couldn't merge", isPresented: $mergeFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Merging the audio failed. Nothing was changed.")
        }
```

And add the hint helper to `HomeScreen`:

```swift
    private var eligibilityHint: String? {
        switch eligibility {
        case .eligible: nil
        case .tooFew:
            selectedKeys.isEmpty
                ? "Select conversations to merge"
                : "Select at least two conversations"
        case .multipleDays: "Select conversations from the same day"
        case .notAllDone: "Wait for transcription to finish"
        }
    }
```

ADAPT-ALLOWED: exact modifier placement (which view in the chain carries `.toolbar` / `.safeAreaInset`) may need adjustment to satisfy the existing structure — keep behavior identical. If `.selectionDisabled` on the header rows still shows selection circles for them in edit mode, wrap the header Section's contents in a plain `Group` and apply it there.

- [ ] **Step 3: Build and run the full suite**

Run: `xcodebuild build -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone Air' 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`, zero warnings.

Run: `xcodebuild test -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone Air' 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **` — the whole suite, not only the new tests.

- [ ] **Step 4: Update `docs/SPEC.md`**

In the "File output" section, after the Retention bullet (line ~287), add:

```markdown
- **Merging (2026-07-06):** the user can merge 2+ same-day, fully-transcribed conversations into one (confirm-then-permanent). The merged file takes the earliest part's basename and standard frontmatter (`duration` = sum of parts, `speechEnd` = last part's, `backend` = `mixed` when parts disagree, `speakers` = max across parts); parts are joined with `> N min gap — resumed H:MM AM` markers (plus "speaker numbers restart" between two diarized parts — labels are never renumbered). Audio is stitched only when every part still has its .m4a; otherwise the merged conversation is transcript-only. Title/summary regenerate best-effort (M8 semantics). Merge — and, since the same change, delete — propagate removals to the sync mirror (M11) best-effort. Design: docs/superpowers/specs/2026-07-06-merge-conversations-design.md.
```

- [ ] **Step 5: Manual verification checklist (simulator)**

Boot the app in the simulator (`xcrun simctl` or Xcode). If prior test fixtures aren't visible, create two short recordings (or drop two fixture .md files into the app container's `Documents/Sotto/<today>/` via `xcrun simctl get_app_container booted com.decanlys.Sotto data`). Then verify:
- Select appears top-left when history exists; tapping enters checkmark selection; status header/banners/gap rows show no checkmarks.
- Merge button disabled with 1 selection ("Select at least two conversations"), across two days ("Select conversations from the same day").
- Merging 2 same-day conversations: confirmation dialog → single merged row remains, detail view shows both parts' text with the gap marker.

- [ ] **Step 6: Commit**

```bash
git add Sotto/App/ContentView.swift docs/SPEC.md
git commit -m "feat: merge-conversations selection UI + SPEC note"
```

---

## Self-Review Notes (already applied)

- Spec coverage: UI flow → Task 9; merged format → Task 2; audio → Tasks 1/3; ordering/crash safety → Task 2 (ordering encoded in `merge`), Task 5 (rebuild parity); notes → Tasks 4/8; mirror incl. delete fix → Tasks 6/8; error table → Tasks 3 (abort), 8 (returns false), 9 (alert); testing section → each task's tests.
- Type consistency: `Outcome`/`MergeError`/`applyMerge`/`remove(m4aURL:from:)`/`mergeEligibility`/`mergeSegments` names match across Tasks 2→9.
- Known accepted divergences (documented in code comments): index `title` stores the raw model title while the file stores the sanitized one (existing M8 precedent); keepSevenDays clock restarts for stitched audio (spec "Accepted wrinkle").

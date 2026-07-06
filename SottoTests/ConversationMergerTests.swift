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

        // wordCount parity: the entry must match what a rebuild-from-frontmatter would
        // compute for the merged file (the spec's rebuild-parity constraint).
        #expect(outcome.mergedEntry.wordCount != nil)
        #expect(outcome.mergedEntry.wordCount
            == DayIndexRebuilder.rebuild(dayDirectory: dir).segments[0].wordCount)
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
        #expect(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("10-01-00.m4a").path))
    }
}

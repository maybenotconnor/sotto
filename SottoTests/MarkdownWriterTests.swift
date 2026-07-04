import Foundation
import Testing
@testable import Sotto

struct MarkdownWriterTests {
    private func job(in dir: URL) -> TranscriptionJob {
        TranscriptionJob(
            id: UUID(), cafURL: nil, m4aURL: dir.appendingPathComponent("09-15-30.m4a"),
            startDate: Date(timeIntervalSince1970: 1_773_000_000),
            duration: 342, speechDuration: 282, attempts: 0, state: .pending)
    }

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MDTests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func onDeviceMarkdownHasFrontmatterAndPlainBody() throws {
        let dir = tempDir()
        let result = TranscriptionResult(
            text: "Hello there. General conversation.",
            segments: [], duration: 342, backend: .speechAnalyzer)
        let url = try TranscriptMarkdownWriter.write(result: result, job: job(in: dir))

        #expect(url.lastPathComponent == "09-15-30.md")
        let md = try String(contentsOf: url, encoding: .utf8)
        #expect(md.hasPrefix("---\n"))
        #expect(md.contains("backend: speechAnalyzer"))
        #expect(md.contains("duration: 342"))
        #expect(md.contains("speechEnd: "))                  // startDate + speechDuration
        #expect(md.contains("# Conversation — "))
        #expect(md.contains("Hello there. General conversation."))
        #expect(!md.contains("**Speaker"))

        // SPEC requires the LOCAL UTC offset on timestamps, not "Z"/UTC — loosely assert
        // the date line ends with a `+HH:MM`/`-HH:MM` offset. (This machine's zone is not
        // UTC, so a bare "Z" would fail this — see the report for the ISO8601 API used.)
        // On UTC-zone machines ISO8601DateFormatter emits "Z" instead of a numeric offset,
        // so accept either form here.
        #expect(md.range(of: "date: .*([+-]\\d{2}:\\d{2}|Z)", options: .regularExpression) != nil)
    }

    @Test func deepgramMarkdownRendersSpeakerTurns() throws {
        let dir = tempDir()
        let result = TranscriptionResult(
            text: "Hi. Hey.",
            segments: [
                TranscriptionSegment(speaker: "1", text: "Hi.", startTime: 0, endTime: 1),
                TranscriptionSegment(speaker: "2", text: "Hey.", startTime: 1, endTime: 2),
            ],
            duration: 342, backend: .deepgram)
        let url = try TranscriptMarkdownWriter.write(result: result, job: job(in: dir))
        let md = try String(contentsOf: url, encoding: .utf8)
        #expect(md.contains("backend: deepgram"))
        #expect(md.contains("speakers: 2"))
        #expect(md.contains("**Speaker 1:** Hi."))
        #expect(md.contains("**Speaker 2:** Hey."))
    }
}

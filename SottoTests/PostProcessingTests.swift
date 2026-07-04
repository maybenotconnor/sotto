import Foundation
import FoundationModels
import Testing
@testable import Sotto

struct PostProcessingTests {
    @Test func shortTranscriptIsRejectedBeforeTouchingTheModel() async throws {
        let processor = FoundationModelsPostProcessor()
        let tiny = TranscriptionResult(
            text: "Hi there.", segments: [], duration: 2, backend: .speechAnalyzer)
        await #expect(throws: PostProcessingError.self) {
            _ = try await processor.process(transcript: tiny, audio: nil)
        }
    }

    @Test func realModelGeneratesGroundedNotes() async throws {
        // Runs for real where Apple Intelligence is available (verified on this dev Mac's
        // simulator); self-skips elsewhere so CI without AI still passes.
        guard FoundationModelsPostProcessor.isModelAvailable else { return }
        let transcript = TranscriptionResult(
            text: """
            Okay so quick sync on the rollout. The beta build went to the internal group \
            on Tuesday and crash-free sessions are at ninety nine point six percent. Maria \
            said the onboarding drop-off improved after we cut the third screen. Two things \
            before Friday: Devon will file for the export compliance review, and I'll draft \
            the release notes. If the compliance review clears we ship to TestFlight external \
            next Monday. Anything else? No? Great, short one.
            """,
            segments: [], duration: 95, backend: .speechAnalyzer)

        let notes = try await FoundationModelsPostProcessor()
            .process(transcript: transcript, audio: nil)

        let title = try #require(notes.title)
        #expect(!title.isEmpty && title.split(separator: " ").count <= 12)
        let summary = try #require(notes.summary)
        #expect(summary.count > 20)
        // Grounding smoke check: the notes should echo the transcript's domain.
        let corpus = (title + " " + summary + " " + (notes.actionItems ?? []).joined(separator: " "))
            .lowercased()
        #expect(corpus.contains("rollout") || corpus.contains("release")
            || corpus.contains("beta") || corpus.contains("testflight")
            || corpus.contains("compliance") || corpus.contains("ship"))
    }
}

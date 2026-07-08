# M8 — Foundation Models Meeting Title + Summary Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the spec's dormant `PostProcessor` hook with an on-device Foundation Models processor that generates a meeting **title**, **summary**, and **action items** after each transcription, surfaces them in the markdown, index, list, and detail screens — plus the adopted meeting-notetaker positioning copy pass (Task 1).

**Architecture:** The `TranscriptionQueue` gains an optional `postProcessorProvider`; after a successful transcription it runs the processor **non-fatally** (generation failure or model unavailability never fails the job — the transcript ships without notes). `FoundationModelsPostProcessor` uses `@Generable` guided generation (`MeetingNotes { title, summary, actionItems }`) against `SystemLanguageModel.default`, truncating long transcripts to fit the on-device context window. `TranscriptMarkdownWriter` renders `title:` frontmatter + `## Summary` / action items / `## Transcript` sections; `TranscriptFile` parses them back (preview prefers the summary); `DaySegmentEntry` carries `title` for list rows. Verified today: Foundation Models reports `available` inside the iPhone Air simulator on this Mac — the real-model integration test runs here and self-skips elsewhere.

**Tech Stack:** FoundationModels (`LanguageModelSession`, `@Generable`/`@Guide` — API verified against the iOS 26.5 swiftinterface), Swift 6 strict concurrency, Swift Testing.

## Global Constraints

- Test command: `xcodebuild test -project Sotto.xcodeproj -scheme Sotto -destination 'platform=iOS Simulator,name=iPhone Air' 2>&1 | tail -5` → `** TEST SUCCEEDED **`. New files → `xcodegen generate`. Zero Swift warnings (appintents exempt). Swift 6, `SWIFT_DEFAULT_ACTOR_ISOLATION: nonisolated`.
- Verified SDK facts (do not re-derive): `LanguageModelSession(model: SystemLanguageModel = .default, tools: [any Tool] = [], instructions: String? = nil)`; `func respond<Content: Generable>(to prompt: String, generating type: Content.Type, ...) async throws -> Response<Content>`; `@Generable(description:)` and `@Guide(description:)` macros; `SystemLanguageModel.default.availability` (`.available` / `.unavailable(reason)`). ADAPT-ALLOWED zone: the exact member exposing the generated value on `Response<Content>` (expected `.content`) — grep the FoundationModels swiftinterface if it differs; record it.
- Post-processing is strictly BEST-EFFORT: any throw from the processor leaves the job `.done` with the plain transcript — never burns attempts, never fails a job, never blocks the drain beyond its own await.
- Transcript context guard: prompt input truncated to the first 6,000 characters (on-device context is small); transcripts under 25 words skip processing entirely (nothing meaningful to title).
- Real-model tests must be availability-gated (`guard case .available = SystemLanguageModel.default.availability else { return }`) so suites pass on machines without Apple Intelligence.
- Existing contracts survive (queue drain semantics, index/writer formats remain backward-readable: files WITHOUT title/summary must keep parsing exactly as today).
- Commits end with:

  Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>

## File Structure

```
Sotto/App/OnboardingView.swift             ← card 1 meeting-frame copy (modify)
docs/SPEC.md                               ← positioning + PostProcessingResult amendments (modify)
Sotto/PostProcessing/PostProcessing.swift  ← protocol + result types (spec, + title)
Sotto/PostProcessing/FoundationModelsPostProcessor.swift
Sotto/Transcription/TranscriptionQueue.swift   ← postProcessorProvider + notes into writer/transition (modify)
Sotto/Transcription/TranscriptMarkdownWriter.swift ← title frontmatter + Summary/Transcript sections (modify)
Sotto/Files/TranscriptFile.swift           ← title/summary/transcriptBody accessors; preview prefers summary (modify)
Sotto/Files/DayIndex.swift + DayIndexStore.swift + DayIndexRebuilder.swift ← title field (modify)
Sotto/App/AppModel.swift                   ← provider wiring + transition title (modify)
Sotto/App/HistoryListView.swift + ConversationDetailView.swift ← surface title/summary (modify)
SottoTests/PostProcessingTests.swift (new); MarkdownWriterTests, TranscriptFileTests, DayIndexTests,
TranscriptionQueueTests, Fakes.swift, RecorderIntegrationTests (modify)
```

---

### Task 1: Meeting-positioning copy pass

**Files:**
- Modify: `Sotto/App/OnboardingView.swift`, `docs/SPEC.md`

- [ ] **Step 1: Onboarding card 1** (`OnboardingView.swift`, the first `card(...)` call): title `"Your notetaker that starts itself"`, body `"Sotto notices when a conversation starts and takes notes automatically — no record button to remember. Recording and transcription stay on your phone."` (icon/tint unchanged).

- [ ] **Step 2: SPEC.md amendments.**
  1. In "App Store strategy", insert after the first paragraph: `> [!NOTE] **Positioning (adopted 2026-07-04): "AI notetaker that starts itself — auto-detects your meetings."** The observed app behavior is a user-initiated session with background continuation (the already-approved Otter/Just Press Record pattern); "all-day" is a user choice, not app behavior. Store metadata, review notes, and onboarding copy use the meeting-notetaker frame. Marketing must never say "records everything all day."`
  2. In "UI specification → 5. Onboarding" card 1 line: append `_(copy updated 2026-07-04 to the meeting-notetaker frame: "Your notetaker that starts itself.")_`
  3. In "Post-processing hook": append to the paragraph: `_(M8, 2026-07-04: implemented via Foundation Models — `PostProcessingResult` gained `title: String?`; generation is best-effort and never fails a transcription job.)_`

- [ ] **Step 3: Full suite green (copy-only; no behavior), commit:** `git add Sotto/App/OnboardingView.swift docs/SPEC.md && git commit -m "feat: adopt meeting-notetaker positioning in onboarding and spec"`

---

### Task 2: PostProcessing types + FoundationModelsPostProcessor

**Files:**
- Create: `Sotto/PostProcessing/PostProcessing.swift`, `Sotto/PostProcessing/FoundationModelsPostProcessor.swift`
- Modify: `SottoTests/Fakes.swift`
- Test: `SottoTests/PostProcessingTests.swift`

**Interfaces (produced; Tasks 3/4 rely on):**

```swift
struct PostProcessingResult: Codable, Sendable, Equatable {
    let title: String?
    let summary: String?
    let actionItems: [String]?
    let custom: [String: String]?
}

enum PostProcessingError: Error { case modelUnavailable, transcriptTooShort }

protocol PostProcessor: Sendable {
    func process(transcript: TranscriptionResult, audio: URL?) async throws -> PostProcessingResult
}

struct FoundationModelsPostProcessor: PostProcessor {
    static var isModelAvailable: Bool { get }   // SystemLanguageModel.default.availability == .available
}
```

- [ ] **Step 1: Create `Sotto/PostProcessing/PostProcessing.swift`** (the types above verbatim, with the spec doc comment: "SPEC 'Post-processing hook', implemented M8: best-effort meeting notes; `title` added to the spec's result shape").

- [ ] **Step 2: Create `Sotto/PostProcessing/FoundationModelsPostProcessor.swift`:**

```swift
import Foundation
import FoundationModels

/// On-device meeting notes via Apple's Foundation Models (iOS 26). Availability follows
/// Apple Intelligence: gate with `isModelAvailable`; callers treat every throw as
/// "no notes", never as a failed transcription.
struct FoundationModelsPostProcessor: PostProcessor {
    static var isModelAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    /// On-device context is small: title/summary come from the opening portion of long
    /// transcripts. 6,000 chars ≈ well under the context ceiling with instructions.
    private static let maxPromptCharacters = 6_000
    private static let minimumWords = 25

    @Generable(description: "Concise notes about one recorded conversation or meeting")
    struct MeetingNotes {
        @Guide(description: "A specific, concrete title for this conversation, at most 8 words, no quotes")
        let title: String
        @Guide(description: "A 2-4 sentence summary of what was discussed and any decisions made")
        let summary: String
        @Guide(description: "Concrete action items or follow-ups that were mentioned; empty if none")
        let actionItems: [String]
    }

    func process(transcript: TranscriptionResult, audio: URL?) async throws -> PostProcessingResult {
        guard Self.isModelAvailable else { throw PostProcessingError.modelUnavailable }
        let words = transcript.text.split { $0.isWhitespace || $0.isNewline }
        guard words.count >= Self.minimumWords else { throw PostProcessingError.transcriptTooShort }

        let session = LanguageModelSession(instructions: """
            You turn raw conversation transcripts into brief meeting notes. Be factual and \
            specific; never invent names, dates, or decisions that are not in the transcript. \
            If the transcript is casual conversation rather than a meeting, title and \
            summarize it plainly.
            """)
        let excerpt = String(transcript.text.prefix(Self.maxPromptCharacters))
        let response = try await session.respond(
            to: "Transcript:\n\n\(excerpt)",
            generating: MeetingNotes.self)
        let notes = response.content   // ADAPT-ALLOWED: grep Response<Content> if `.content` differs
        return PostProcessingResult(
            title: notes.title.isEmpty ? nil : notes.title,
            summary: notes.summary.isEmpty ? nil : notes.summary,
            actionItems: notes.actionItems.isEmpty ? nil : notes.actionItems,
            custom: nil)
    }
}
```

- [ ] **Step 3: `FakePostProcessor` in Fakes.swift:**

```swift
struct FakePostProcessor: PostProcessor {
    var result = PostProcessingResult(
        title: "Fake standup", summary: "We discussed fakes.", actionItems: ["Ship it"], custom: nil)
    var error: Error?

    func process(transcript: TranscriptionResult, audio: URL?) async throws -> PostProcessingResult {
        if let error { throw error }
        return result
    }
}
```

- [ ] **Step 4: Tests — `SottoTests/PostProcessingTests.swift`:**

```swift
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
```

(Generation latency is seconds — acceptable in the suite; note the wall time in your report. If the grounding assertion proves flaky across runs, loosen to title+summary non-empty ONLY, record the observed outputs, and note the flake.)

- [ ] **Step 5: `xcodegen generate`, suite green, commit:** `git add Sotto/PostProcessing SottoTests && git commit -m "feat: Foundation Models meeting-notes post-processor"`

---

### Task 3: Queue + markdown + parser + index plumbing

**Files:**
- Modify: `Sotto/Transcription/TranscriptionQueue.swift`, `Sotto/Transcription/TranscriptMarkdownWriter.swift`, `Sotto/Files/TranscriptFile.swift`, `Sotto/Files/DayIndex.swift`, `Sotto/Files/DayIndexStore.swift`, `Sotto/Files/DayIndexRebuilder.swift`, `Sotto/App/AppModel.swift`
- Test: `SottoTests/MarkdownWriterTests.swift`, `SottoTests/TranscriptFileTests.swift`, `SottoTests/TranscriptionQueueTests.swift`, `SottoTests/DayIndexTests.swift` (extend)

**Interfaces:**

```swift
// TranscriptionQueue: init gains postProcessorProvider: (@Sendable () -> (any PostProcessor)?)? = nil
//   (both designated + the convenience init(service:) forward it). Worker: after transcribe
//   succeeds and the m4a still exists, `let notes = try? await postProcessorProvider?()?
//   .process(transcript: result, audio: m4aURL)` (best-effort); pass into the writer and
//   the transition.
// JobTransition gains: let notes: PostProcessingResult?   (nil on failure/no processor)
// TranscriptMarkdownWriter.write(result:job:) → write(result:notes: PostProcessingResult? = nil, job:)
//   Frontmatter gains `title: <t>` when notes?.title != nil (after `backend:`). Heading uses
//   the title when present: `# <title> — 9:15 AM` else the existing `# Conversation — 9:15 AM`.
//   Body: when summary/actionItems present:
//     ## Summary\n\n<summary>\n\n[Action items:\n- item…\n\n]## Transcript\n\n<existing body>
//   When notes nil → EXACTLY today's output (byte-compatible; existing tests must not change).
// TranscriptFile gains: var title: String? (frontmatter), var summary: String?
//   (section between "## Summary" and the next "## "), var transcriptBody: String
//   (after "## Transcript" if present, else the whole body); previewText prefers summary.
// DaySegmentEntry gains: var title: String? = nil (decodeIfPresent — old indexes still load).
// DayIndexStore.updateSegment gains title: String? = nil (sets when non-nil).
// DayIndexRebuilder: done entries read frontmatter["title"].
// AppModel wiring: queue init gets postProcessorProvider: { FoundationModelsPostProcessor.isModelAvailable ? FoundationModelsPostProcessor() : nil };
//   transition handler passes transition.notes?.title into updateSegment.
```

- [ ] **Step 1: Failing tests.** MarkdownWriterTests:

```swift
    @Test func notesRenderTitleSummaryAndTranscriptSections() throws {
        let dir = tempDir()
        let result = TranscriptionResult(
            text: "We synced on the rollout.", segments: [], duration: 60, backend: .speechAnalyzer)
        let notes = PostProcessingResult(
            title: "Rollout sync", summary: "Quick status sync.", actionItems: ["File compliance"], custom: nil)
        let url = try TranscriptMarkdownWriter.write(result: result, notes: notes, job: job(in: dir))
        let md = try String(contentsOf: url, encoding: .utf8)
        #expect(md.contains("title: Rollout sync"))
        #expect(md.contains("# Rollout sync — "))
        #expect(md.contains("## Summary"))
        #expect(md.contains("Quick status sync."))
        #expect(md.contains("- File compliance"))
        #expect(md.contains("## Transcript"))
        #expect(md.contains("We synced on the rollout."))
    }
```

TranscriptFileTests:

```swift
    @Test func parsesTitleSummaryAndTranscriptSections() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TFTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("t.md")
        try """
        ---
        date: 2026-03-14T09:15:30-04:00
        backend: speechAnalyzer
        title: Rollout sync
        ---

        # Rollout sync — 9:15 AM

        ## Summary

        Quick status sync about the beta.

        Action items:
        - File compliance

        ## Transcript

        We synced on the rollout and the beta numbers.
        """.write(to: url, atomically: true, encoding: .utf8)

        let file = try #require(TranscriptFile.parse(url: url))
        #expect(file.title == "Rollout sync")
        #expect(file.summary?.contains("Quick status sync") == true)
        #expect(file.transcriptBody.contains("We synced on the rollout"))
        #expect(!file.transcriptBody.contains("## Summary"))
        #expect(file.previewText.hasPrefix("Quick status sync"))   // preview prefers summary
    }

    @Test func filesWithoutNotesParseExactlyAsBefore() throws {
        // Reuse the existing fixture from parsesFrontmatterBodyAndPreview and additionally
        // assert title == nil, summary == nil, transcriptBody == body.
        // (Copy that fixture here verbatim rather than referencing it.)
    }
```

(Write the third test out fully by copying the existing fixture — no cross-references.) TranscriptionQueueTests:

```swift
    @Test func postProcessorNotesLandInMarkdownAndTransition() async throws {
        let dir = tempDir()
        let box = Mutex<PostProcessingResult?>(nil)
        let queue = TranscriptionQueue(
            storeURL: dir.appendingPathComponent("jobs.json"),
            serviceProvider: { FakeTranscriptionService(text: "we synced on many important things and decided a plan of action for the release") },
            rootDirectory: dir,
            postProcessorProvider: { FakePostProcessor() })
        await queue.setTransitionHandler { transition in
            box.withLock { $0 = transition.notes }
        }
        await queue.enqueue(try makeSegment(in: dir.appendingPathComponent("a")))
        await queue.drain()

        let md = try String(
            contentsOf: dir.appendingPathComponent("a/seg.md"), encoding: .utf8)
        #expect(md.contains("title: Fake standup"))
        #expect(md.contains("## Summary"))
        #expect(box.withLock { $0 }?.title == "Fake standup")
    }

    @Test func postProcessorFailureStillCompletesTheJobPlainly() async throws {
        struct Boom: Error {}
        let dir = tempDir()
        let queue = TranscriptionQueue(
            storeURL: dir.appendingPathComponent("jobs.json"),
            serviceProvider: { FakeTranscriptionService(text: "plain transcript") },
            rootDirectory: dir,
            postProcessorProvider: { FakePostProcessor(error: Boom()) })
        await queue.enqueue(try makeSegment(in: dir.appendingPathComponent("a")))
        await queue.drain()

        #expect(await queue.jobs.first?.state == .done)      // never fails the job
        let md = try String(
            contentsOf: dir.appendingPathComponent("a/seg.md"), encoding: .utf8)
        #expect(!md.contains("## Summary"))
        #expect(md.contains("plain transcript"))
    }
```

(`FakePostProcessor` needs a memberwise-with-defaults init for `FakePostProcessor(error:)` — adjust the fake accordingly.) DayIndexTests: extend `updateAndAudioRemovalMutateTheRightEntry` with `title: "Rollout sync"` passed and asserted, and add a rebuild fixture line `title: Rollout sync` asserting `segments[0].title == "Rollout sync"` in the rebuild test.

- [ ] **Step 2: RED → implement per the Interfaces block.** Byte-compatibility rule: with `notes == nil` the writer's output must be identical to today (all existing markdown tests pass untouched). In the queue's done path, run the processor AFTER the m4a-exists guard and BEFORE `TranscriptMarkdownWriter.write`; `try? await` so throws degrade to `notes = nil`.

- [ ] **Step 3: GREEN, commit:** `git add Sotto SottoTests && git commit -m "feat: meeting notes flow through queue, markdown, parser, and index"`

---

### Task 4: UI surfacing + integration + e2e

**Files:**
- Modify: `Sotto/App/HistoryListView.swift`, `Sotto/App/ConversationDetailView.swift`, `SottoTests/RecorderIntegrationTests.swift`

- [ ] **Step 1: List rows** (`SegmentRowView`): when `entry.title` is non-nil, show it as the row's primary line (`.font(.headline)`, `lineLimit(1)`) with the time + duration moving to the secondary line; otherwise the existing time-first layout. (Preview line already prefers the summary via `TranscriptFile.previewText` — no change.)

- [ ] **Step 2: Detail:** `navigationTitle` = `entry.title ?? startTime-formatted` (keep time in the metadata row); render `transcript.summary` (when present) in a distinct section — a `GroupBox("Summary") { Text(summary) }` above the transcript — and render `transcript.transcriptBody` (not the raw body) as the transcript text, so the `##` markers never appear as literal text.

- [ ] **Step 3: Integration:** extend the whole-stack test's queue with `postProcessorProvider: { FakePostProcessor() }` and assert the final `.md` contains `title: Fake standup` and the index entry's `title == "Fake standup"`.

- [ ] **Step 4: Full suite green; rebuild + reinstall + launch on iPhone Air + screenshot to the session scratchpad; commit:** `git add Sotto SottoTests && git commit -m "feat: surface meeting titles and summaries in list and detail"`

## Self-review notes

- Spec coverage: PostProcessor hook implemented per "Post-processing hook" (types now Codable ✓, spec amended for `title` in Task 1); best-effort semantics preserve every M4 queue contract; markdown remains backward-readable (no-notes output byte-identical, old files parse with nil title/summary — pinned by tests).
- Positioning: onboarding card 1 + SPEC App Store strategy + Post-processing amendments in Task 1; no behavior change.
- Type consistency: `PostProcessingResult(title:summary:actionItems:custom:)` argument order used identically in fake, processor, writer tests; `write(result:notes:job:)` default `notes: nil` keeps every existing call site compiling; `JobTransition.notes` consumed only in AppModel + tests; `DaySegmentEntry.title` uses `decodeIfPresent` so M5-era `_day.json` files load.
- Known risks flagged: `Response.content` member name (adapt zone); real-model test latency + potential grounding flake (loosening rule stated).

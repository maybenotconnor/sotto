# Head + Tail Transcript Summaries Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Generate on-device meeting notes from the opening *and* closing of long transcripts (not just the head), and honestly disclose in the written notes when only excerpts were summarized.

**Architecture:** `FoundationModelsPostProcessor` builds a head+tail excerpt (joined by an omission marker) instead of a head-only prefix, and flags the result `truncated`. A single shared `summarySection` helper renders the `## Summary` block for both markdown write paths and appends a disclaimer line when `truncated`. No UI changes — the disclaimer is markdown in the `.md`, rendered by the existing transcript view.

**Tech Stack:** Swift, Apple FoundationModels (on-device), Swift Testing (`import Testing`, `@Test`, `#expect`, `#require`), xcodebuild.

## Global Constraints

- **Deployment target stays iOS 26.0.** Do NOT use the iOS 26.4 APIs `tokenCount(for:)` or `contextSize`. No `#available` branch, no target bump.
- **Head budget = 5,000 characters; tail budget = 5,000 characters.**
- **Omission marker, verbatim:** `\n\n[... middle of the conversation omitted ...]\n\n`
- **Disclaimer line, verbatim:** `_Summary based on excerpts of the transcript. Important information may have been omitted._`
- **Byte-compat invariant:** the no-notes and complete-notes (`truncated == false`) markdown must be byte-identical to today's output. The disclaimer is the only new bytes and appears only when `truncated == true`.
- **Sanitization choke point unchanged:** model output is still sanitized in the callers (`TranscriptMarkdownWriter.sanitizeInline` / `sanitizeBlock`). The disclaimer is trusted app text and deliberately bypasses the sanitizers (it is a single structure-safe line).
- **Commit messages:** plain, conventional-commit style. No `Co-Authored-By` / attribution trailers (repo convention).
- **Test command** (any booted iOS 26 iPhone simulator works; `iPhone Air` is the repo's documented default):
  ```bash
  xcodebuild test -project Sotto.xcodeproj -scheme Sotto \
    -destination 'platform=iOS Simulator,name=iPhone Air' \
    -only-testing:SottoTests/<SuiteName>
  ```
  The first `xcodebuild` invocation resolves SPM packages and is slow (minutes). Do not treat slowness as a hang.

---

## File Structure

- **Modify** `Sotto/PostProcessing/PostProcessing.swift` — add `truncated` to `PostProcessingResult`.
- **Modify** `Sotto/PostProcessing/FoundationModelsPostProcessor.swift` — replace the head-only `maxPromptCharacters` slice with a pure `promptExcerpt(for:)` helper (head + marker + tail) and thread `truncated` through `process`.
- **Modify** `Sotto/Transcription/TranscriptMarkdownWriter.swift` — add the shared `summarySection(summary:actionItems:truncated:)` helper and the `excerptDisclaimer` constant; rewire `write` to use the helper.
- **Modify** `Sotto/Files/ConversationMerger.swift` — rewire `applyNotes` to use the shared helper (deletes the duplicated Summary block).
- **Test** `SottoTests/PostProcessingTests.swift`, `SottoTests/MarkdownWriterTests.swift`, `SottoTests/ConversationMergerTests.swift`.

---

## Task 1: Head + tail excerpt with truncation flag

**Files:**
- Modify: `Sotto/PostProcessing/PostProcessing.swift:5-10`
- Modify: `Sotto/PostProcessing/FoundationModelsPostProcessor.swift:13-50`
- Test: `SottoTests/PostProcessingTests.swift`

**Interfaces:**
- Produces: `PostProcessingResult` gains `var truncated: Bool = false` (last stored property; keeps the memberwise init backward-compatible).
- Produces: `static func promptExcerpt(for text: String) -> (excerpt: String, truncated: Bool)` on `FoundationModelsPostProcessor` (internal; callable from tests via `@testable import Sotto`).
- Consumes: nothing from other tasks.

- [ ] **Step 1: Write the failing tests**

Append these three tests inside the `PostProcessingTests` struct in `SottoTests/PostProcessingTests.swift` (before the closing `}`):

```swift
    @Test func shortTranscriptIsSentWholeWithoutTruncation() {
        let text = String(repeating: "word ", count: 100)   // ~500 chars, well under 10k
        let (excerpt, truncated) = FoundationModelsPostProcessor.promptExcerpt(for: text)
        #expect(excerpt == text)
        #expect(truncated == false)
    }

    @Test func longTranscriptIsExcerptedHeadAndTailWithMarker() {
        let head = String(repeating: "A", count: 5_000)
        let middle = String(repeating: "B", count: 20_000)
        let tail = String(repeating: "C", count: 5_000)
        let (excerpt, truncated) = FoundationModelsPostProcessor.promptExcerpt(for: head + middle + tail)
        #expect(truncated == true)
        #expect(excerpt.hasPrefix(head))                 // opening 5k preserved
        #expect(excerpt.hasSuffix(tail))                 // closing 5k preserved
        #expect(!excerpt.contains("B"))                  // entire middle dropped
        #expect(excerpt.contains("[... middle of the conversation omitted ...]"))
        // Marker appears exactly once.
        #expect(excerpt.components(separatedBy: "[... middle of the conversation omitted ...]").count == 2)
    }

    @Test func excerptBoundaryAtExactlyHeadPlusTailIsNotTruncated() {
        let text = String(repeating: "x", count: 10_000)   // == head + tail, so NOT > threshold
        let (excerpt, truncated) = FoundationModelsPostProcessor.promptExcerpt(for: text)
        #expect(truncated == false)
        #expect(excerpt == text)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:
```bash
xcodebuild test -project Sotto.xcodeproj -scheme Sotto \
  -destination 'platform=iOS Simulator,name=iPhone Air' \
  -only-testing:SottoTests/PostProcessingTests
```
Expected: **BUILD FAILS** — `type 'FoundationModelsPostProcessor' has no member 'promptExcerpt'`. (In Swift, a missing symbol is the red state.)

- [ ] **Step 3: Add the `truncated` field**

In `Sotto/PostProcessing/PostProcessing.swift`, change the struct (lines 5-10) to:

```swift
struct PostProcessingResult: Codable, Sendable, Equatable {
    let title: String?
    let summary: String?
    let actionItems: [String]?
    let custom: [String: String]?
    /// True when the transcript was too long to send whole and only head+tail excerpts were
    /// summarized. Drives the "based on excerpts" disclaimer in the written notes. Last
    /// property + default keeps the synthesized memberwise init backward-compatible.
    var truncated: Bool = false
}
```

- [ ] **Step 4: Implement the excerpt helper and wire it into `process`**

In `Sotto/PostProcessing/FoundationModelsPostProcessor.swift`, replace the constants block (lines 13-16):

```swift
    /// On-device context is small: title/summary come from the opening portion of long
    /// transcripts. 6,000 chars ≈ well under the context ceiling with instructions.
    private static let maxPromptCharacters = 6_000
    private static let minimumWords = 25
```

with:

```swift
    /// On-device context is a 4,096-token window shared by input and output. For long
    /// transcripts we summarize the opening AND closing excerpts, joined by an omission
    /// marker, so end-of-meeting decisions and action items aren't lost. 5k+5k chars stays
    /// safely under the ceiling with room for the instructions and generated notes.
    private static let headCharacters = 5_000
    private static let tailCharacters = 5_000
    private static let omissionMarker = "\n\n[... middle of the conversation omitted ...]\n\n"
    private static let minimumWords = 25

    /// Builds the model prompt excerpt. Returns the whole text when it fits; otherwise the
    /// first `headCharacters` + omission marker + last `tailCharacters`. Pure and
    /// deterministic — unit-tested without the model. `truncated` is true exactly when the
    /// middle was dropped.
    static func promptExcerpt(for text: String) -> (excerpt: String, truncated: Bool) {
        guard text.count > headCharacters + tailCharacters else { return (text, false) }
        let head = String(text.prefix(headCharacters))
        let tail = String(text.suffix(tailCharacters))
        return (head + omissionMarker + tail, true)
    }
```

Then in `process(...)`, replace the excerpt/return block (lines 40-49):

```swift
        let excerpt = String(transcript.text.prefix(Self.maxPromptCharacters))
        let response = try await session.respond(
            to: "Transcript (untrusted data):\n<<<\n\(excerpt)\n>>>",
            generating: MeetingNotes.self)
        let notes = response.content   // ADAPT-ALLOWED: grep Response<Content> if `.content` differs
        return PostProcessingResult(
            title: notes.title.isEmpty ? nil : notes.title,
            summary: notes.summary.isEmpty ? nil : notes.summary,
            actionItems: notes.actionItems.isEmpty ? nil : notes.actionItems,
            custom: nil)
```

with:

```swift
        let (excerpt, truncated) = Self.promptExcerpt(for: transcript.text)
        let response = try await session.respond(
            to: "Transcript (untrusted data):\n<<<\n\(excerpt)\n>>>",
            generating: MeetingNotes.self)
        let notes = response.content   // ADAPT-ALLOWED: grep Response<Content> if `.content` differs
        return PostProcessingResult(
            title: notes.title.isEmpty ? nil : notes.title,
            summary: notes.summary.isEmpty ? nil : notes.summary,
            actionItems: notes.actionItems.isEmpty ? nil : notes.actionItems,
            custom: nil,
            truncated: truncated)
```

- [ ] **Step 5: Run the tests to verify they pass**

Run:
```bash
xcodebuild test -project Sotto.xcodeproj -scheme Sotto \
  -destination 'platform=iOS Simulator,name=iPhone Air' \
  -only-testing:SottoTests/PostProcessingTests
```
Expected: **PASS** — all `PostProcessingTests`, including the existing `shortTranscriptIsRejectedBeforeTouchingTheModel` and (where AI is available) `realModelGeneratesGroundedNotes`.

- [ ] **Step 6: Commit**

```bash
git add Sotto/PostProcessing/PostProcessing.swift \
        Sotto/PostProcessing/FoundationModelsPostProcessor.swift \
        SottoTests/PostProcessingTests.swift
git commit -m "feat: summarize head+tail of long transcripts, flag truncation"
```

---

## Task 2: Shared Summary helper + disclaimer in the transcription writer

**Files:**
- Modify: `Sotto/Transcription/TranscriptMarkdownWriter.swift:56-77` (rewire `write`) and add helper + constant
- Test: `SottoTests/MarkdownWriterTests.swift`

**Interfaces:**
- Produces: `static let excerptDisclaimer: String` and
  `static func summarySection(summary: String?, actionItems: [String]?, truncated: Bool) -> [String]`
  on `TranscriptMarkdownWriter`. Inputs are already-sanitized values. Returns `[]` when there
  is no notes body (preserving the byte-compat invariant); otherwise the `## Summary` … `## Transcript`
  block, with the disclaimer appended before `## Transcript` when `truncated`.
- Consumes: `PostProcessingResult.truncated` from Task 1.

- [ ] **Step 1: Write the failing tests**

Append these two tests inside the `MarkdownWriterTests` struct in `SottoTests/MarkdownWriterTests.swift` (before the closing `}`):

```swift
    @Test func truncatedNotesRenderExcerptDisclaimer() throws {
        let dir = tempDir()
        let result = TranscriptionResult(
            text: "We synced on the rollout.", segments: [], duration: 60, backend: .speechAnalyzer)
        let notes = PostProcessingResult(
            title: "Rollout sync", summary: "Quick status sync.",
            actionItems: ["File compliance"], custom: nil, truncated: true)
        let url = try TranscriptMarkdownWriter.write(result: result, notes: notes, job: job(in: dir))
        let md = try String(contentsOf: url, encoding: .utf8)
        #expect(md.contains("based on excerpts of the transcript"))
        // Disclaimer lives inside the Summary section, before the Transcript heading.
        let disc = try #require(md.range(of: "based on excerpts of the transcript"))
        let transcript = try #require(md.range(of: "## Transcript"))
        #expect(disc.lowerBound < transcript.lowerBound)
    }

    @Test func completeNotesHaveNoDisclaimer() throws {
        let dir = tempDir()
        let result = TranscriptionResult(
            text: "We synced on the rollout.", segments: [], duration: 60, backend: .speechAnalyzer)
        let notes = PostProcessingResult(
            title: "Rollout sync", summary: "Quick status sync.",
            actionItems: ["File compliance"], custom: nil)   // truncated defaults false
        let url = try TranscriptMarkdownWriter.write(result: result, notes: notes, job: job(in: dir))
        let md = try String(contentsOf: url, encoding: .utf8)
        #expect(!md.contains("based on excerpts of the transcript"))
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:
```bash
xcodebuild test -project Sotto.xcodeproj -scheme Sotto \
  -destination 'platform=iOS Simulator,name=iPhone Air' \
  -only-testing:SottoTests/MarkdownWriterTests
```
Expected: `truncatedNotesRenderExcerptDisclaimer` **FAILS** (the disclaimer substring is not found). `completeNotesHaveNoDisclaimer` passes already. (Both compile — `truncated:` exists from Task 1.)

- [ ] **Step 3: Add the disclaimer constant and shared helper**

In `Sotto/Transcription/TranscriptMarkdownWriter.swift`, add these to the `TranscriptMarkdownWriter` enum (place directly above the `sanitizeInline` function near the bottom):

```swift
    /// Trusted app text (NOT model output — bypasses the sanitizers) appended to the Summary
    /// section when the notes were built from head+tail excerpts of a long transcript.
    static let excerptDisclaimer =
        "_Summary based on excerpts of the transcript. Important information may have been omitted._"

    /// The `## Summary` … `## Transcript` block, shared by the transcription writer and
    /// `ConversationMerger.applyNotes`. Inputs are already sanitized. Returns `[]` when there
    /// is no notes body, so the caller's transcript body renders in the exact pre-notes shape
    /// (byte-compat invariant). The disclaimer is appended before `## Transcript` when truncated.
    static func summarySection(summary: String?, actionItems: [String]?, truncated: Bool) -> [String] {
        let hasNotesBody = summary != nil || actionItems?.isEmpty == false
        guard hasNotesBody else { return [] }
        var lines: [String] = ["## Summary", ""]
        if let summary {
            lines.append(summary)
            lines.append("")
        }
        if let actionItems, !actionItems.isEmpty {
            lines.append("Action items:")
            for item in actionItems {
                lines.append("- \(item)")
            }
            lines.append("")
        }
        if truncated {
            lines.append(excerptDisclaimer)
            lines.append("")
        }
        lines.append("## Transcript")
        lines.append("")
        return lines
    }
```

- [ ] **Step 4: Rewire `write` to use the helper**

In `Sotto/Transcription/TranscriptMarkdownWriter.swift`, replace the byte-compat comment + `hasNotesBody` block (lines 56-77):

```swift
        // Byte-compatibility (Task 3 BINDING invariant): with `notes == nil` (or a notes
        // value with neither summary nor action items), the body below is EXACTLY today's
        // shape — no "## Transcript" heading inserted — so every pre-M8 markdown/rebuild
        // test keeps passing unmodified.
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
```

with:

```swift
        // Byte-compatibility (BINDING invariant): with no notes body the helper returns [],
        // so the transcript body below renders in EXACTLY today's shape (no "## Transcript"
        // heading) and every pre-M8 markdown/rebuild test keeps passing unmodified.
        lines.append(contentsOf: Self.summarySection(
            summary: sanitizedSummary, actionItems: sanitizedActionItems,
            truncated: notes?.truncated ?? false))
```

- [ ] **Step 5: Run the tests to verify they pass**

Run:
```bash
xcodebuild test -project Sotto.xcodeproj -scheme Sotto \
  -destination 'platform=iOS Simulator,name=iPhone Air' \
  -only-testing:SottoTests/MarkdownWriterTests
```
Expected: **PASS** — the two new tests plus the existing `notesRenderTitleSummaryAndTranscriptSections` and `modelOutputCannotInjectFrontmatterOrSections` (which prove the non-truncated output is unchanged).

- [ ] **Step 6: Commit**

```bash
git add Sotto/Transcription/TranscriptMarkdownWriter.swift SottoTests/MarkdownWriterTests.swift
git commit -m "feat: disclaimer for excerpt-based summaries via shared summarySection helper"
```

---

## Task 3: Use the shared helper in the merge/regeneration path

**Files:**
- Modify: `Sotto/Files/ConversationMerger.swift:148-165` (inside `applyNotes`)
- Test: `SottoTests/ConversationMergerTests.swift`

**Interfaces:**
- Consumes: `TranscriptMarkdownWriter.summarySection(summary:actionItems:truncated:)` from Task 2 and `PostProcessingResult.truncated` from Task 1.
- Produces: nothing new.

- [ ] **Step 1: Write the failing test**

Append this test inside the `ConversationMergerTests` struct in `SottoTests/ConversationMergerTests.swift` (place it right after `applyNotesRewritesWithTitleSummaryAndPreservedTranscript`, before `applyNotesSanitizesModelOutput`):

```swift
    @Test func applyNotesRendersExcerptDisclaimerWhenTruncated() async throws {
        let dir = try makeDay([("09-15-30", Self.partOne), ("10-01-00", Self.partTwo)])
        let entries = DayIndexRebuilder.rebuild(dayDirectory: dir).segments
        _ = try await ConversationMerger.merge(dayDirectory: dir, entries: entries)
        let mdURL = dir.appendingPathComponent("09-15-30.md")

        let ok = ConversationMerger.applyNotes(
            to: mdURL,
            notes: PostProcessingResult(
                title: "Planning the launch", summary: "We planned the launch.",
                actionItems: ["Ship it"], custom: nil, truncated: true),
            startTime: entries[0].startTime)

        #expect(ok)
        let file = try #require(TranscriptFile.parse(url: mdURL))
        #expect(file.summary?.contains("Important information may have been omitted") == true)
        // Transcript body — gap marker included — still preserved verbatim.
        #expect(file.transcriptBody.contains("First part text one two three."))
        #expect(file.transcriptBody.contains("Second part text four five."))
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run:
```bash
xcodebuild test -project Sotto.xcodeproj -scheme Sotto \
  -destination 'platform=iOS Simulator,name=iPhone Air' \
  -only-testing:SottoTests/ConversationMergerTests
```
Expected: `applyNotesRendersExcerptDisclaimerWhenTruncated` **FAILS** (`file.summary` does not contain the disclaimer — `applyNotes` still renders its own duplicated block).

- [ ] **Step 3: Rewire `applyNotes` to use the shared helper**

In `Sotto/Files/ConversationMerger.swift`, replace the `hasNotesBody` block (lines 148-165):

```swift
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
```

with:

```swift
        lines.append(contentsOf: TranscriptMarkdownWriter.summarySection(
            summary: sanitizedSummary, actionItems: sanitizedActionItems,
            truncated: notes.truncated))
```

- [ ] **Step 4: Run the test to verify it passes**

Run:
```bash
xcodebuild test -project Sotto.xcodeproj -scheme Sotto \
  -destination 'platform=iOS Simulator,name=iPhone Air' \
  -only-testing:SottoTests/ConversationMergerTests
```
Expected: **PASS** — the new test plus the existing `applyNotesRewritesWithTitleSummaryAndPreservedTranscript` and `applyNotesSanitizesModelOutput` (which prove the non-truncated merge output is unchanged).

- [ ] **Step 5: Run the full suite**

Run (no `-only-testing` filter):
```bash
xcodebuild test -project Sotto.xcodeproj -scheme Sotto \
  -destination 'platform=iOS Simulator,name=iPhone Air'
```
Expected: **PASS** — whole `SottoTests` target green, confirming the shared helper and new field broke nothing.

- [ ] **Step 6: Commit**

```bash
git add Sotto/Files/ConversationMerger.swift SottoTests/ConversationMergerTests.swift
git commit -m "refactor: merge path shares summarySection, gets excerpt disclaimer"
```

---

## Self-Review

**Spec coverage:**
- Head+tail excerpt with marker + `truncated` flag → Task 1. ✓
- 5k+5k sizing, no 26.4 APIs → Global Constraints + Task 1 constants. ✓
- Short-transcript / boundary (no split, no disclaimer) → Task 1 tests. ✓
- `PostProcessingResult.truncated` (`var … = false`, decode-safe) → Task 1 Step 3. ✓
- Shared `summarySection` helper removing duplication → Task 2 (helper) + Task 3 (merger reuse). ✓
- Disclaimer wording + placement (after action items, before `## Transcript`) → Task 2 helper + tests. ✓
- Byte-compat invariant (no-notes / complete-notes unchanged) → helper returns `[]` / omits disclaimer; guarded by existing tests kept passing in Tasks 2 & 3. ✓
- Both write paths emit the disclaimer → Task 2 (write) + Task 3 (applyNotes). ✓
- No UI changes → confirmed; disclaimer is markdown rendered by the existing view. ✓

**Placeholder scan:** none — every code and command step is concrete.

**Type consistency:** `promptExcerpt(for:) -> (excerpt: String, truncated: Bool)`, `PostProcessingResult(..., truncated:)`, and `summarySection(summary:actionItems:truncated:) -> [String]` are used identically wherever they appear across tasks.

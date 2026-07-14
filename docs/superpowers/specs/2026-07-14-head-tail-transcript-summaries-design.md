# Head + Tail Transcript Summaries — Design

**Date:** 2026-07-14
**Status:** Approved design, pending implementation plan

## Problem

On-device meeting notes (M8, `FoundationModelsPostProcessor`) are generated from
`transcript.text.prefix(6_000)` — only the opening ~1,000 words. For a long conversation
(the ~14k-word transcript that motivated the recent lazy-render fix), the title, summary,
**and action items** are derived from roughly the first 7% of the conversation; everything
after the opening is silently dropped. This is worst for action items, which in meetings
cluster near the **end** — exactly the part head-only truncation discards. The recent
"longer conversations" work fixed transcript *rendering* only; the summarization path was
untouched.

Apple's on-device model has a hard **4,096-token context window shared by input and
output**, so the excerpt cannot simply be enlarged without bound — an overflow throws
`exceededContextWindowSize`, which this code swallows as *no notes at all*.

## Decisions (from brainstorming)

| Question | Decision |
|---|---|
| Coverage strategy | Head **+ tail** excerpt (not head-only, not map-reduce). Captures opening context and closing decisions/action items in a single model call. |
| Budget | `~5,000` chars head + `~5,000` chars tail (≈10k chars). Conservative: fits 4,096 tokens even at a pessimistic ~3.5 chars/token, leaving room for instructions + generated notes. |
| Token measurement | **None.** Keep deployment target at iOS 26.0; do not adopt the 26.4 `tokenCount(for:)` / `contextSize` APIs. Accept a slightly under-filled window in exchange for one code path on every iOS 26.x. |
| Short transcripts | If `text.count <= head + tail`, send the whole text; no split, no disclaimer. |
| Seam | Explicit marker `[... middle of the conversation omitted ...]` between the two slices so the model treats them as two windows on one conversation, not continuous prose. |
| Disclosure | When truncated, a footnote line in the `## Summary` section: *Summary based on excerpts of the transcript. Important information may have been omitted.* |
| Disclaimer placement | Written into the `.md` (source of truth), rendered automatically by `ConversationDetailView`. **No UI code changes.** |
| Duplication | Fold the two `## Summary` renderers (`TranscriptMarkdownWriter.write`, `ConversationMerger.applyNotes`) into one shared helper; add the disclaimer once. |
| Not doing | Map-reduce / full-coverage summarization. Remains the future path if disclosed head+tail proves insufficient. |

## Overview

For a long transcript the model now sees the first ~5k and last ~5k characters, joined by
an omission marker, and the resulting notes are marked truncated. The `.md` writer adds a
single italic disclaimer line to the Summary section when (and only when) notes were
truncated. Short transcripts and the no-notes case are byte-identical to today, preserving
the existing markdown byte-compatibility invariant.

## Excerpt strategy — `FoundationModelsPostProcessor`

Replace the single `maxPromptCharacters = 6_000` head slice with a pure, testable helper:

```swift
static func promptExcerpt(for text: String) -> (excerpt: String, truncated: Bool)
```

- Constants: `headCharacters = 5_000`, `tailCharacters = 5_000`.
- If `text.count <= headCharacters + tailCharacters` → return `(text, false)`. No overlap,
  no marker, no disclaimer.
- Else → `text.prefix(headCharacters)` + `"\n\n[... middle of the conversation omitted ...]\n\n"`
  + `text.suffix(tailCharacters)`, and `truncated = true`.
- Polish (optional, decided during implementation): nudge each cut to the nearest
  whitespace so a slice does not begin/end mid-word. Not required for correctness.

`process(...)` calls the helper, feeds `excerpt` to the session (inside the existing
untrusted-data framing — the seam marker is app-controlled trusted text and is not an
instruction), and threads `truncated` into the returned `PostProcessingResult`. The
`minimumWords` guard and availability gate are unchanged and still apply to the full text.

**Why 5k+5k and not the 6k+6k first proposed:** 12k chars ≈ 3,000+ input tokens; with
instructions (~120) and the generated notes (~700 reserved), a pessimistic char→token
ratio can push past 4,096 and throw. Without `tokenCount` we cannot detect that boundary,
and an overflow yields *no notes*, which is worse than a slightly smaller excerpt. 5k+5k
stays safe across ratios.

## Result shape — `PostProcessingResult`

Add `var truncated: Bool = false` as the **last** stored property.

- **Decode-safety: verified.** `PostProcessingResult` is `Codable` for conformance only — a
  grep confirms it is never JSON-encoded or decoded anywhere; it is a transient DTO
  (processor → writer / `applyNotes`). So a plain non-optional `Bool` is safe; no `Bool?`
  or custom decoder needed.
- **Declaring it `var … = false` (last) keeps the synthesized memberwise initializer
  backward-compatible:** the new parameter is defaulted and trailing, so every existing
  construction site — the four test/fake sites and the complete-notes path — compiles
  unchanged. Only the processor's truncated branch passes `truncated: true`. Tests that
  assert truncation opt in explicitly.
- `Codable` / `Equatable` / `Sendable` conformance is retained.

## Disclaimer rendering — shared Summary helper

The `## Summary` section is currently built in two near-identical places:
`TranscriptMarkdownWriter.write` and `ConversationMerger.applyNotes`. Extract one helper
(home: `TranscriptMarkdownWriter`, reused by the merger):

```swift
static func summarySection(summary: String?, actionItems: [String]?, truncated: Bool) -> [String]
```

- Emits the exact current lines: `## Summary`, the summary block, an `Action items:` list,
  then `## Transcript`.
- When `truncated == true`, appends one italic footnote line at the end of the Summary
  section (after action items, before `## Transcript`):

  > *Summary based on excerpts of the transcript. Important information may have been omitted.*

- The disclaimer is trusted app text (not model output), so it does **not** pass through
  the untrusted-model sanitizers, but it is a single structure-safe line and cannot alter
  frontmatter or headings.
- Both writers call this helper, removing the current duplication. `ConversationMerger`
  passes `notes.truncated`; `TranscriptMarkdownWriter.write` passes it from the
  `PostProcessingResult` it received.

`ConversationDetailView` renders the `.md` as markdown (now via the lazy AttributedString
blocks), so the disclaimer appears as its own small block with no view changes.

## Byte-compatibility

- **No notes** (or notes with neither summary nor action items): the Summary section is
  not emitted at all — unchanged.
- **Complete notes** (`truncated == false`): the helper produces byte-identical output to
  today — no disclaimer line.
- **Truncated notes** (`truncated == true`): the only new bytes in the whole system — one
  footnote line inside the Summary section.

The `hasNotesBody` gate and the "no `## Transcript` heading when there is no notes body"
invariant are preserved by keeping that branching in the callers (or inside the helper,
matched exactly). Existing writer / rebuild / merge tests pass unmodified.

## Error handling

| Failure | Outcome |
|---|---|
| Model unavailable / Low Power / transcript too short | Unchanged — no notes, never a failed transcription. Truncation logic never reached. |
| Excerpt still overflows the window (mis-estimated ratio) | Session throws; caught as today (`try?`) → no notes. 5k+5k is sized to make this vanishingly unlikely. |
| Very long single action item pushes output past the window | Same swallow-as-no-notes behavior as today; not newly introduced by this change. |
| Merge/regeneration path | `regenerateNotes` → `applyNotes` uses the same helper, so a merged conversation gets the same disclaimer treatment; no divergence between the two write paths. |

## Testing

- **`promptExcerpt` (pure, no model):** short text (< 10k) → whole text, `truncated == false`,
  no marker; long text (> 10k) → `prefix` + marker + `suffix`, `truncated == true`;
  boundary at exactly `head + tail`; marker present exactly once; head and tail content
  come from the right ends.
- **`summarySection` helper:** `truncated == false` → byte-identical to the current Summary
  block (guards the byte-compat invariant); `truncated == true` → footnote line present,
  positioned after action items and before `## Transcript`.
- **Both write paths:** `TranscriptMarkdownWriter.write` and `ConversationMerger.applyNotes`
  each emit the disclaimer when `truncated` and omit it otherwise (extend
  `MarkdownWriterTests` / `ConversationMergerTests`).
- **`PostProcessingTests`:** existing tests updated for the new field; add coverage that a
  truncated result carries `truncated == true` end to end where the model is faked.

## Out of scope

- Map-reduce / hierarchical (full-coverage) summarization.
- iOS 26.4 token-measurement APIs (`tokenCount(for:)`, `contextSize`) and any deployment
  target bump.
- Time-based disclosure ("covers the first N minutes") — we do not measure timing, only
  character position.
- Any `ConversationDetailView` / UI layout change.

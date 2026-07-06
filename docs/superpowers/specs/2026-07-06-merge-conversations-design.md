# Merge Conversations — Design

**Date:** 2026-07-06
**Status:** Approved design, pending implementation plan

## Problem

The silence timeout splits recordings into segments. Sometimes one real conversation
pauses longer than the timeout and lands on disk as several `.m4a`/`.md` pairs. The user
needs a way to select those conversations in the app and merge them into one.

## Decisions (from brainstorming)

| Question | Decision |
|---|---|
| Merged transcript content | Concatenate existing `.md` transcript bodies (never re-transcribe) |
| Reversibility | Confirmation dialog, then permanent |
| Audio | Stitch into one `.m4a` when ALL parts have audio; otherwise transcript-only |
| Meeting notes (M8) | Regenerate title/summary/action items from merged text, best-effort |
| Selection scope | Same day only, any 2+ conversations, all `transcriptionState == "done"` |
| Sync mirror (M11) | Export merged + remove parts from mirror; ALSO fix `deleteSegment` to remove from mirror |
| Deepgram speakers | Keep labels unchanged; reset note at gaps; `speakers:` = max across parts |
| Architecture | Approach A: dedicated `ConversationMerger` unit in `Sotto/Files/` |

## Overview

The merged conversation is written under the **earliest part's basename** and is
indistinguishable from a normally-recorded conversation: same frontmatter keys, same
index entry shape, **no new schema**. `DayIndexRebuilder`, list rendering, preview,
retention, and sync all work on merged files unchanged.

New unit: `ConversationMerger` in `Sotto/Files/` owns the file-level operation.
`AppModel` orchestrates: selection UI state, confirmation, calling the merger, notes
regeneration, `PreviewCache` invalidation, sync mirror updates, history refresh.

## UI flow

- History list gains a selection mode (long-press a row or Select button → standard
  SwiftUI edit-mode multi-select with checkmarks).
- A **Merge** action (bottom toolbar) enables when: ≥2 selected, all in the same day
  section, all `transcriptionState == "done"`. When disabled by a rule, a short footnote
  explains why ("Select conversations from the same day" / "Wait for transcription to
  finish").
- Confirmation dialog mirrors delete: *"Merge 3 conversations into one? The originals
  are replaced. This can't be undone."*
- On confirm: merge runs, selection mode exits, list refreshes to the single merged row.
  Title/summary appear on the row later if notes regeneration succeeds.

## Merged file format

**Basename:** earliest part's (e.g. `09-15-30`). Other parts' files are deleted.

**Frontmatter** — same keys as a recorded file:

| Key | Value |
|---|---|
| `date` | earliest part's `date` |
| `duration` | **sum** of part durations (recorded content, not wall-clock span) |
| `speechEnd` | latest part's `speechEnd` |
| `backend` | common value if all parts agree, else `mixed` |
| `speakers` | max across parts that have the key; omitted if none do |
| `title` | absent initially; added when notes regeneration succeeds |

**Body:** each part's `transcriptBody` (via the existing `TranscriptFile` parser —
per-part `## Summary` sections and `# Conversation — …` / titled heading lines are
dropped), joined chronologically with a gap marker between consecutive parts:

```markdown
# Conversation — 9:15 AM

<part 1 transcript>

> 41 min gap — resumed 10:42 AM

<part 2 transcript>
```

Gap length = next part's `date` minus previous part's `speechEnd` (fallback:
`date + duration`), rendered coarsely ("41 min", "2 hr 5 min"). When the parts on
**both** sides of a gap carry Deepgram speaker labels, the marker gains a reset note:

```markdown
> 41 min gap — resumed 10:42 AM · speaker numbers restart
```

Speaker labels in bodies are never rewritten — Speaker 0 in part 1 and part 2 may be
the same person; renumbering would assert distinctness we have no evidence for.

After notes regeneration the file is rewritten once with `title:` frontmatter, the
titled H1, and `## Summary` / `## Transcript` sections — exactly the M8 shape, with gap
markers living inside the `## Transcript` section.

## Audio

- **All parts have `.m4a`:** stitch via `AVMutableComposition` +
  `AVAssetExportSession`, passthrough preset first (parts share a format — all come from
  the same recording pipeline — so no re-encode); fall back to AAC re-encode if
  passthrough is rejected. Result becomes the merged `.m4a`.
- **Any part lacks audio:** merged conversation is transcript-only; surviving part
  audio is deleted with the parts.
- **Stitch fails:** merge aborts with an error alert; nothing on disk is modified
  (stitching runs first, to a temp file).

Accepted wrinkle: under `keepSevenDays` retention the stitched `.m4a` is a new file, so
its 7-day clock restarts from the merge. Harmless; not worth special-casing.

## Operation ordering (crash safety)

1. Stitch audio to a temp file in the day folder (skip if transcript-only).
2. Write merged `.md` atomically over the earliest part's `.md` (temp + rename).
3. Move stitched audio over the earliest part's `.m4a`.
4. Delete the other parts' `.md`/`.m4a` files.
5. Update `_day.json` (part entries replaced by one merged entry; `wordCount`
   recounted from the merged body; `hasAudio` per steps 3–4; `transcriptionState:
   "done"`).

Create the new truth before deleting the old: a crash mid-sequence can leave
**duplicate** content (merged file + stale parts) but never lost content, and the
rebuild-from-frontmatter path already renders that state sanely — the user deletes
leftovers. File protection: `completeUntilFirstUserAuthentication`, as everywhere.

## Notes regeneration

After the local merge commits, `AppModel` wraps the merged transcript text in a minimal
`TranscriptionResult` and runs the existing `PostProcessor` — M8 semantics exactly:

- **Success:** rewrite the `.md` (one more atomic write, via the merger's renderer),
  update the index entry's `title`, invalidate `PreviewCache`, re-export to the mirror.
- **Failure:** merged file keeps its default heading; silent. Never fails the merge.

## Sync mirror (M11)

New counterpart to `SegmentExporter.export`: a coordinated, best-effort
`remove(m4aURL:from:)` that deletes `<day>/<basename>.md` + `.m4a` from the
destination. Used in two places:

- **Merge:** export the merged conversation; remove the merged-away parts.
- **Delete (gap fix):** `deleteSegment` now also removes the deleted conversation from
  the mirror, so local deletes finally propagate.

All mirror work stays best-effort and detached off the main actor, like the existing
export path — a cloud hiccup never fails a local operation.

## Error handling summary

| Failure | Outcome |
|---|---|
| Audio stitch fails | Merge aborted, alert shown, nothing changed |
| Crash mid-merge | Duplicate content possible, no data loss; index rebuilds sanely |
| Notes regeneration fails | Merged file keeps default heading — silent, like M8 |
| Mirror export/remove fails | Silent best-effort; local state is truth |

## Testing

- **`ConversationMergerTests`** (temp-dir, like `SegmentStoreTests`): frontmatter
  computation (duration sum, speechEnd, backend agree/mixed, speakers max), gap markers
  (length text, speaker-reset note only between two diarized parts), per-part Summary and
  heading stripping, audio-presence combos, part-file deletion, index update, and a
  **rebuild-parity test** — after a merge, `DayIndexRebuilder` output equals the stored
  index.
- **Audio stitch test** with small generated AAC fixtures (stitched duration ≈ sum of
  parts; passthrough fallback path exercised where the environment allows).
- **Exporter removal tests:** coordinated delete from a temp "destination";
  `deleteSegment` mirror propagation.
- **Selection-rule tests** on AppModel logic (same-day, ≥2, all-done gating).

## Out of scope

- Cross-day merges (a conversation split across midnight lives in two folders).
- Unmerge / undo after confirmation.
- Re-transcription of stitched audio.
- Re-diarization. The design deliberately never mangles speaker labels, so if on-device
  diarization (FluidAudio, roadmap) lands, merged files with full audio can be
  re-diarized for true consistent labels.

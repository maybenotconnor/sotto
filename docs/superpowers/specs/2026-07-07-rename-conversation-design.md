# Rename Conversation — Design

**Date:** 2026-07-07
**Status:** Approved design, pending implementation plan

## Problem

Conversation titles are model-generated (M8 meeting notes) or absent (a bare time like
"9:15 AM"). The user wants to rename a conversation by tapping its title in the detail
view and editing it in place.

## Decisions (from brainstorming)

| Question | Decision |
|---|---|
| Rename surface | Detail view only (no Home-list context menu) |
| Interaction | Native `navigationTitle(Binding<String>)` rename — tap title → system "Rename" menu → inline nav-bar edit |
| Title display mode | `.navigationBarTitleDisplayMode(.inline)` on the detail view (required by the binding affordance) |
| Empty / unchanged input | No-op — the field reverts; clearing a title back to nil is out of scope |
| Segments without a `.md` | Not renamable (static title) — `_day.json` is rebuilt from `.md` frontmatter, so a rename would not survive |
| Sanitization | User input passes through `TranscriptMarkdownWriter.sanitizeInline`, the same choke point as model output |
| Architecture | `applyTitle` alongside `applyNotes` in `ConversationMerger`; `AppModel.renameSegment` orchestrates |

## Overview

A renamed conversation is indistinguishable from one whose title came from the M8
post-processor: same `title:` frontmatter key, same `# <title> — <time>` H1, same index
entry field. **No new schema.** Rebuild, list rendering, preview, retention, and sync
all work unchanged.

## UI flow — `ConversationDetailView`

- `@State private var editableTitle: String`, seeded on load with `entry.title`, else
  the formatted start time (exactly what the static title shows today).
- `.navigationTitle($editableTitle)` + `.navigationBarTitleDisplayMode(.inline)` when
  the transcript file parsed; a plain non-editable `navigationTitle` otherwise
  (queued/failed segments).
- On commit (`.onChange(of: editableTitle)`), persist only when the trimmed value is
  non-empty **and** differs from the value that was displayed. Committing unchanged
  text, or clearing the field, reverts silently — this also prevents the time
  placeholder from being persisted as a literal title.

## Persistence — `ConversationMerger.applyTitle`

`applyTitle(to mdURL: URL, title: String, startTime: Date) -> Bool`

- Parses via `TranscriptFile`, sets `title:` in frontmatter, re-renders the
  `# <title> — <time>` H1, and leaves the rest of the body (Summary, action items,
  Transcript, gap markers) untouched. Unknown hand-edited frontmatter keys survive,
  sorted — same canonical-key rendering as `applyNotes`.
- Title is sanitized with `TranscriptMarkdownWriter.sanitizeInline` (newlines
  collapsed, leading `#`/`-` stripped, 120-char cap) before rendering. A title that
  sanitizes to empty aborts the rename (returns false).
- Atomic write + `completeUntilFirstUserAuthentication` file protection, as everywhere.

## Choreography — `AppModel.renameSegment(m4aURL:title:)`

Follows the `regenerateNotes` precedent:

1. `ConversationMerger.applyTitle` rewrites the `.md` (source of truth). On failure,
   stop — the index is never updated ahead of the file.
2. `DayIndexStore.setTitle(m4aURL:title:)` — a small new mutation on the existing
   `mutateEntry` helper.
3. Best-effort detached mirror export (`SegmentExporter.export`) when a sync
   destination resolves.
4. `refreshLoadedHistory()` so the Home list shows the new title immediately.

## Error handling summary

| Failure | Outcome |
|---|---|
| `.md` missing/unparseable | Title not editable (UI); `applyTitle` returns false if it races |
| Title sanitizes to empty | Rename aborted, UI reverts |
| Mirror export fails | Silent best-effort; local state is truth |
| Crash between file write and index update | Index shows stale title until next rebuild/update — same "keep-stale by design" precedent as notes |
| Re-transcribe after rename | Title dropped. Re-transcribe rewrites the `.md` from scratch (`TranscriptMarkdownWriter`) and re-adds a `title:` only if notes regeneration produces one — a user rename is lost identically to a model-generated title. Consistent with "indistinguishable from an M8 title"; not special-cased. |

## Testing

- **`applyTitle` unit tests** (temp-dir, like `ConversationMergerTests`): frontmatter
  `title:` set on files with and without an existing title; H1 re-rendered with the
  original start time; Summary/Transcript body preserved byte-for-byte; unknown
  frontmatter keys survive; sanitization applied; empty-after-sanitize returns false.
- **Rebuild round-trip:** after `applyTitle`, `DayIndexRebuilder.rebuild` yields the
  new title — proves a rename survives index loss.
- **`DayIndexStore.setTitle` test:** entry title updated, other fields untouched.

## Out of scope

- Renaming from the Home list.
- Clearing a title back to "no title".
- Renaming segments whose transcript hasn't been produced (queued/failed).

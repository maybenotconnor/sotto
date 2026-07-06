# Live Activity Redesign — Design

**Date:** 2026-07-06
**Status:** Approved (brainstorm with Connor)

## Problem

The Live Activity's compact Dynamic Island shows a bare, unlabeled integer (the
session's finalized-segment count). Users can't tell what it means, and the count
isn't important enough to earn that slot. Separately, the compact Island renders
Listening and Recording identically (same waveform glyph), so the activity doesn't
show what the VAD actually thinks — the most glanceable fact the app has.

Root cause: `ContentState` carries a display string (`stateLabel`) plus `isPaused`,
so the widget can't branch on real state without parsing English.

## Decisions

1. **Conversation count**: keep it on the lock screen only, where it is labeled
   ("· 3 conversations"). Remove it from all Dynamic Island views.
2. **Compact Dynamic Island shows VAD state**: listening vs recording vs paused,
   via a state-colored glyph. Nothing else.
3. **Disk-space warning**: deferred; it will be a local notification, NOT a Live
   Activity state (SPEC amendment — see below).
4. **Merge conversations**: queued as future work (see below), not designed here.

## Design

### 1. Data contract — `Sotto/LiveActivity/SottoActivityAttributes.swift`

```swift
struct SottoActivityAttributes: ActivityAttributes {
    enum Phase: String, Codable, Hashable {
        case listening, recording, pausedByUser, pausedBySystem
    }
    struct ContentState: Codable, Hashable {
        var phase: Phase
        var conversationCount: Int
    }
    let startedAt: Date   // unchanged — feeds the self-ticking timer
}
```

- `stateLabel` and `isPaused` are removed. The widget derives the label
  ("Listening" / "Recording" / "Paused by you" / "Paused — call") and paused-ness
  from `phase`.
- Recorder state `.silence` maps to `.listening` (as its label does today).
- The "Stopped" terminal content is dropped: `sessionEnded()` ends with
  `end(nil, dismissalPolicy: .immediate)` — the current "Stopped" content is never
  visible because dismissal is immediate.
- File stays dependency-free (compiled by both app and widget targets).

### 2. Controller & pipeline — `LiveActivityControlling.swift`, `ListeningPipeline.swift`

- Protocol method becomes `update(phase: SottoActivityAttributes.Phase,
  conversationCount: Int)`.
- `sessionStarted(at:)` requests the activity with `(.listening, 0)`.
- `endAllStale()` unchanged.
- In `ListeningPipeline`, `activityLabel(for:)` becomes `activityPhase(for:)` —
  same shape, returns `Phase`; `haltReason` still selects `.pausedByUser` vs
  `.pausedBySystem`. The update-only-on-change logic in `apply()` is untouched.
- Label formatting leaves the app entirely (widget concern; localizable later).

### 3. Widget UI — `SottoWidgets/SottoWidgetsBundle.swift`

State visuals (shared by all surfaces):

| Phase          | Glyph                | Tint   |
|----------------|----------------------|--------|
| listening      | `waveform`           | green  |
| recording      | `record.circle.fill` | red    |
| pausedByUser / pausedBySystem | `pause.circle.fill` (lock screen, expanded); `pause.fill` (compact, minimal) | orange |

- **Lock screen**: same layout as today — glyph, phase label headline, caption row
  of elapsed timer + "· N conversations" (labeled count stays), Pause/Resume button
  (`ToggleListeningIntent`, unchanged). Glyph/tints now three-way per the table.
- **Dynamic Island compact**: leading = state glyph with tint; trailing = empty
  (bare count removed). Minimal = same glyph.
- **Dynamic Island expanded**: leading = glyph, center = phase label, trailing =
  elapsed timer `Text(startedAt, style: .timer)` (replaces the bare count),
  bottom = Pause/Resume button.

Red-means-recording matches the OS convention (orange mic dot, Voice Memos), so
the VAD state reads at a glance without text.

### 4. Testing

Update the fake controller and assertions in `SottoTests/Fakes.swift`,
`LiveActivityWiringTests.swift`, `InterruptionTests.swift`,
`ListeningPipelineTests.swift` to the new signature. Assertions strengthen from
label-string matching to `Phase` values:

- listening → recording → listening round trip pushes matching phases
- interruption → `.pausedBySystem`; user pause → `.pausedByUser`
- count-only change (status unchanged) still fires exactly one update
- session end still ends the activity; stale activities still cleaned at launch

The widget view remains untested (no widget test target; declarative rendering).

### 5. SPEC amendments (`docs/SPEC.md`)

- **Content spec (~line 354)**: compact Dynamic Island = VAD-state glyph only, no
  count; expanded Island = state label + elapsed timer + Pause/Resume; lock screen
  keeps state label, timer, labeled conversation count, Pause/Resume.
- **Disk guard (~line 123)**: warn via notification only — drop "+ Live Activity".

## Error handling

No new failure modes: activity requests remain `try?` + authorization-gated;
updates remain fire-and-forget `Task`s. A phase the widget doesn't know can't
occur (enum, both targets compile the same file). In-flight activities from an
old build die at next launch via the existing `endAllStale()`.

## Future work (queued, not designed)

1. **Merge conversations.** VAD over-segments: one real conversation with long
   pauses finalizes as several segments/files, which is also why the raw count
   confused more than it informed. Users will want to merge adjacent conversations
   after the fact — likely multi-select in the history list, concatenating
   transcripts and linking audio. Needs its own brainstorm (file format, sync
   folder implications, undo).
2. **Low-disk notification.** Implement the disk-guard warning as a local
   notification (decided here: not a Live Activity state).

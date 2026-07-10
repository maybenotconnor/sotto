# Home Header Refresh — Design

**Date:** 2026-07-10
**Status:** Approved (brainstormed via visual companion; direction, button placement, and
state treatments selected by Connor)

## Goal

Replace the home screen's stock header — large "Sotto" navigation title, plain status
row, and loose banner strips — with a single state-forward status card in the app's
Porcelain identity. Goals chosen during brainstorming: **state at a glance** (the
screen's most prominent element should be the listening state, not the app name),
**less default-looking** (spend the icon's Porcelain identity on the screen seen most),
and **reduce clutter** (the four stacked strips above history become one composed
object).

The "Sotto" wordmark is dropped entirely; the brand lives in the app icon.

## Decisions and rejected alternatives

- **Direction:** "Porcelain hero" card, restated in iOS 26 Liquid Glass vocabulary.
  Rejected: state-as-large-title (most native but least distinctive) and a title-less
  "quiet strip" (austere but still default-looking).
- **Typography:** SF Pro. An earlier serif treatment was rejected as off-standard —
  Apple reserves serif faces for reading content, not controls.
- **Action button: compact, in the state row.** A full-width 44 pt button was rejected
  after UX critique: it gave the largest tap target to a twice-a-day action, became a
  giant accidental-tap "Stop" surface right where scrolling begins, and had prominence
  without reachability. A bottom-anchored floating capsule (Voice Memos pattern) was
  rejected for splitting attention between two focal points.
- **No red button.** All button states share one style; the action word carries the
  meaning. Red appears only as the pulsing recording dot.
- **No wave animation while recording.** The wave mark is static everywhere; the only
  motion in the card is the existing pulsing dot.
- **Wave mark relocates to the empty state.** The compact button takes the wave's spot
  in the card, so the icon's wave-becomes-text line moves above the empty-state text,
  greeting new users without crowding the working UI.

## Screen structure

- `ContentView` drops `.navigationTitle("Sotto")` with no replacement. The toolbar
  keeps Select (leading, only when history exists) and the gear (trailing); iOS 26
  gives both glass treatment automatically.
- The status card replaces the current `statusCard` + `banners` header section as the
  first list section. It **scrolls away with the list** — unchanged behavior; the
  system mic indicator and Live Activity carry the always-on recording indication.
- History sections, infinite scroll, merge/edit mode, swipe actions, and the merge
  bottom bar are untouched.

## Card anatomy

One Liquid Glass surface: `.glassEffect(.regular, in: .rect(cornerRadius: 26))`
(concentric corner radius), containing:

1. **State row:** status dot (existing `HeaderState.dotColor` colors; `PulsingDot`
   when a segment is open) + state word in `.title2.bold()` Ink + spacer + compact
   capsule button sized to its label.
2. **Subtitle line** (`.footnote`, secondary, monospaced digits for timers):
   - Idle → "Ready to listen"
   - Listening → session timer (existing `timerStart` logic)
   - Recording… → segment timer
   - Starting… / Paused → no subtitle
3. **Footnote rows** (only when notices apply) — see Banners below.

The `HeaderState` machine, its labels (including the "Paused by you" / "Paused — call"
wording and the Omi source suffix "Listening · Omi" when paired), the button labels
(Start Listening / Resume / Stop via the existing `buttonLabel` switch), and the
mic-denied disabled state all carry over unchanged. This is a re-skin of the header,
not a behavior change.

## Action button

- Capsule, compact: sized to its label, ~36 pt visual height, with padding/content
  shape extending the tappable area to the 44 pt HIG minimum.
- One style for all actions: Ink background with white label in light mode; Porcelain
  background with Ink label in dark mode ("ink by day, paper by night", matching the
  icon spec's inversion). Implemented as `.buttonStyle(.glassProminent)` tinted with
  the adaptive Ink asset color.

## Banners → footnotes

The current full-weight banner stack becomes footnote rows inside the card, below a
hairline divider under the subtitle. Same copy, same actions, one row per notice,
stacked when several apply:

| Notice | Row content |
|---|---|
| Recovery notice | text + **Dismiss** |
| Model downloading | `ProgressView(value:)` + existing copy |
| Model not installed | text + **Download** |
| Model download failed | text + **Try again** |
| Device unsupported (on-device engine selected) | text only |
| Mic denied | text + **Open Settings** |
| Bluetooth off / unauthorized (Omi paired) | text + **Open Settings** |
| Low disk space | text only |

Row style: `.footnote` text, leading SF Symbol, trailing bold action; warning rows use
a red symbol tint, not red body text. Symbols: `exclamationmark.triangle` (recovery,
unsupported), `arrow.down.circle` (model rows), `mic.slash` (mic denied), `dot.radiowaves.slash`
(Bluetooth), `externaldrive.badge.exclamationmark` (disk). The standalone `NoticeBanner`
view is retired.

## Empty state

When history is empty and loaded, the empty-state area shows the icon's wave line
(static, Ink at ~55 % opacity) centered above the existing empty-state text. The wave
is drawn as a SwiftUI `Path` from the centerline geometry in the app icon spec
(`docs/superpowers/specs/2026-07-10-app-icon-design.md`), stroked with round caps —
the icon's filled-outline constraint was Icon-Composer-specific and does not apply
in SwiftUI.

## Color

Two adaptive colors in an asset catalog (new — the project currently has none;
XcodeGen wiring mirrors the AppIcon resource):

| Name | Light | Dark |
|---|---|---|
| `Ink` | `#232752` | `#F2F2EF` |
| `Porcelain` | `#F2F2EF` | `#1A1D3C` |

`Ink` tints the button (its dark variant is what produces the paper button at night),
the state word, and the empty-state wave. `Porcelain` is the faint wash behind the
card's glass so the material has something to catch in both modes. Everything else
uses semantic system colors and materials, so dark mode needs no per-view work.
Status dot colors are unchanged from `HeaderState.dotColor`.

## Implementation shape

- New file `Sotto/App/HeroCard.swift`: the card view (state row, subtitle, footnotes)
  plus `HeaderState`, `PulsingDot`, and the footnote row style move here from
  `ContentView.swift` (~500 lines today; the extraction roughly offsets the additions).
- `ContentView.swift`: header section becomes a single `HeroCard(...)`; `statusCard`,
  `banners`, and `NoticeBanner` are deleted; `.navigationTitle` removed; empty-state
  branch gains the wave mark.
- No model, pipeline, or settings changes. Rough size: 150–250 lines across two files
  plus the asset catalog.

## Verification

1. Build and run; drive the pipeline through idle → start → speak → stop and confirm
   each card state (dot, word, timer, button label), including the pulsing dot while
   a segment is open.
2. Deny mic permission in Settings; confirm the footnote row, its Open Settings
   action, and the disabled button.
3. Select the on-device engine on an unsupported device (or simulate) and confirm the
   unsupported footnote replaces today's banner with the same copy.
4. Toggle dark mode: card inverts to ink surface, button to porcelain.
5. Fresh-install state: wave mark + empty-state text render; wave is absent once
   history exists.
6. Dynamic Type at the largest sizes: state row wraps gracefully, button stays
   tappable.
7. Edit mode: card is inert (selection disabled), merge bar unaffected.

## Out of scope

- History rows, day headers, gap rows, detail view.
- Live Activity, widgets, onboarding, Settings screens.
- Any behavior change to the pipeline, recording, or banner trigger conditions.

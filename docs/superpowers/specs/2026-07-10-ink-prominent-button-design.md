# Ink Prominent Button — Design

**Date:** 2026-07-10
**Status:** Approved (follow-up to the home-header-refresh; scope — Ink everywhere,
including the Live Activity — selected by Connor)

## Goal

One named treatment for every prominent action button in Sotto: a Liquid Glass capsule
tinted `Ink` whose label is explicitly `Porcelain`, so both layers invert together —
"ink by day, paper by night". This centralizes the `.glassProminent` quirk found during
the header refresh (commit `084cd90`): the built-in style keeps a light label on the
tint in both modes, which turns white-on-porcelain (unreadable) in dark mode. The
Porcelain identity, previously only on the hero card, extends to onboarding, the merge
bar, and the Live Activity (Connor's call: Ink everywhere; the action word carries the
meaning, extending the header spec's "no red button" philosophy to the lock screen).

## Mechanism

A `View` extension in a new shared file:

```swift
extension View {
    func inkProminent() -> some View {
        self.buttonStyle(.glassProminent)
            .tint(Color("Ink"))
            .foregroundStyle(Color("Porcelain"))
    }
}
```

with the quirk explanation as its doc comment. A custom `ButtonStyle` (call sites
reading `.buttonStyle(.ink)`) was rejected: SwiftUI provides no way to compose the
built-in glass style inside a custom style's `makeBody` — you would reimplement glass
or wrap it awkwardly. The extension is three lines and composes cleanly.

The file must compile in both the app and widget targets (see Plumbing), so it lives at
`Sotto/App/InkProminent.swift` and is added to the `SottoWidgets` sources list the same
way `SottoActivityAttributes.swift` already is.

## Adoption — 7 buttons

| Site | Today | Change |
|---|---|---|
| Hero card action (`HeroCard.swift`) | the 3 modifiers inline | swap for `.inkProminent()` |
| Onboarding ×4 (`OnboardingView.swift:69,77,82,121`) | `.borderedProminent`, stock blue | `.inkProminent()` |
| Merge bar (`ContentView.swift:184`) | `.borderedProminent`, stock blue | `.inkProminent()`; the `ProgressView` shown while merging gets an explicit `Porcelain` tint so the spinner stays visible on ink |
| Live Activity Pause/Resume ×2 (`SottoWidgetsBundle.swift:80,102`) | `.borderedProminent`, green/orange state tints | `.inkProminent()`; state color signal dropped deliberately |

Not touched: plain-text buttons (onboarding "Skip for now", footnote actions), the
bordered utility buttons in `SettingsView`/`HomeRows`, and every semantic-tinted
non-button element (state dots, Live Activity glyphs, onboarding card icons).

## Widget target plumbing

`Color("Ink")` resolves against the running bundle, and a widget extension is its own
bundle — so `project.yml` gives `SottoWidgets` two additions: the shared style file as
a source, and `Sotto/Assets.xcassets` as a resource. No new asset catalog; the same
colorsets ship in both bundles.

**Escape hatch:** Live Activities render in a constrained lock-screen context. If
`.glassProminent` degrades there (no glass, wrong shape, missing tint), the Activity
buttons fall back to `.borderedProminent` + the same Ink/Porcelain pair — same capsule
look without glass. Verification decides which branch ships; the fallback, if needed,
lives in the widget file, not the shared extension.

## Verification

1. Full unit suite green.
2. Simulator screenshots: onboarding pages and merge bar in light and dark — ink
   capsule with porcelain label by day, paper capsule with ink label by night.
3. Start a listening session so the Live Activity posts; check the Pause/Resume button
   on the lock screen / Dynamic Island expanded view in both appearances; apply the
   fallback if glass misrenders.
4. Merge-in-flight state: spinner visible on the ink capsule.

## Out of scope

- Any layout, copy, or behavior change to the buttons' actions.
- Theming beyond these 7 buttons; no design-token system.
- The header refresh PR (#8) — this builds on top of it.

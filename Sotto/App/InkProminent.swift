import SwiftUI

extension View {
    /// Sotto's prominent action treatment: a Liquid Glass capsule tinted Ink whose label
    /// is explicitly Porcelain, so both layers invert together — ink capsule with paper
    /// label by day, paper capsule with ink label at night (the header spec's "ink by
    /// day, paper by night", extended app-wide by the 2026-07-10 ink-prominent spec).
    /// The explicit label color is load-bearing: .glassProminent keeps a light label on
    /// the tint in BOTH modes, which turns white-on-porcelain (unreadable) in dark mode.
    /// Compiled into the app and widget targets; both bundles carry the colorsets.
    func inkProminent() -> some View {
        buttonStyle(.glassProminent)
            .tint(Color("Ink"))
            .foregroundStyle(Color("Porcelain"))
    }
}

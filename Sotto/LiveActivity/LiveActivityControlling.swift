// Activity<T> is not Sendable in this SDK; values cross MainActor→nonisolated update/end calls.
@preconcurrency import ActivityKit
import Foundation

/// Seam over ActivityKit so pipeline wiring is unit-testable. SPEC "Live Activity": the
/// activity runs whenever the app is not Idle and is ended on Stop.
@MainActor
protocol LiveActivityControlling: AnyObject {
    func sessionStarted(at date: Date)
    /// M12: `sourceLabel` mirrors the pipeline's `activeSourceType.displayName` (nil pre-M12
    /// or while nothing is capturing). Use the `update(phase:conversationCount:)` extension
    /// overload below when the caller has no source label to report.
    func update(phase: SottoActivityAttributes.Phase, conversationCount: Int, sourceLabel: String?)
    func sessionEnded()
    /// End every leftover activity from a previous process (iOS keeps them up to 8 h after
    /// a kill). Call at launch and defensively before requesting a fresh one.
    func endAllStale()
}

extension LiveActivityControlling {
    /// Convenience overload for call sites (and fakes) that don't track a source label.
    func update(phase: SottoActivityAttributes.Phase, conversationCount: Int) {
        update(phase: phase, conversationCount: conversationCount, sourceLabel: nil)
    }
}

@MainActor
final class SottoLiveActivityController: LiveActivityControlling {
    private var activity: Activity<SottoActivityAttributes>?

    func endAllStale() {
        for stale in Activity<SottoActivityAttributes>.activities {
            Task { await stale.end(nil, dismissalPolicy: .immediate) }
        }
    }

    func sessionStarted(at date: Date) {
        endAllStale()
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let content = ActivityContent(
            state: SottoActivityAttributes.ContentState(phase: .listening, conversationCount: 0),
            staleDate: nil)
        activity = try? Activity.request(
            attributes: SottoActivityAttributes(startedAt: date), content: content)
    }

    func update(phase: SottoActivityAttributes.Phase, conversationCount: Int, sourceLabel: String?) {
        guard let activity else { return }
        let content = ActivityContent(
            state: SottoActivityAttributes.ContentState(
                phase: phase, conversationCount: conversationCount, sourceLabel: sourceLabel),
            staleDate: nil)
        Task { await activity.update(content) }
    }

    func sessionEnded() {
        guard let activity else { return }
        self.activity = nil
        // Dismissal is immediate, so final content is never visible — end with none.
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }
}

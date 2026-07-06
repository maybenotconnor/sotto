// Activity<T> is not Sendable in this SDK; values cross MainActor→nonisolated update/end calls.
@preconcurrency import ActivityKit
import Foundation

/// Seam over ActivityKit so pipeline wiring is unit-testable. SPEC "Live Activity": the
/// activity runs whenever the app is not Idle and is ended on Stop.
@MainActor
protocol LiveActivityControlling: AnyObject {
    func sessionStarted(at date: Date)
    func update(phase: SottoActivityAttributes.Phase, conversationCount: Int)
    func sessionEnded()
    /// End every leftover activity from a previous process (iOS keeps them up to 8 h after
    /// a kill). Call at launch and defensively before requesting a fresh one.
    func endAllStale()
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

    func update(phase: SottoActivityAttributes.Phase, conversationCount: Int) {
        guard let activity else { return }
        let content = ActivityContent(
            state: SottoActivityAttributes.ContentState(
                phase: phase, conversationCount: conversationCount),
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

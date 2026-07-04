// Activity<T> is not Sendable in this SDK; values cross MainActor→nonisolated update/end calls.
@preconcurrency import ActivityKit
import Foundation

/// Seam over ActivityKit so pipeline wiring is unit-testable. SPEC "Live Activity": the
/// activity runs whenever the app is not Idle and is ended on Stop.
@MainActor
protocol LiveActivityControlling: AnyObject {
    func sessionStarted(at date: Date)
    func update(stateLabel: String, conversationCount: Int, isPaused: Bool)
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
            state: SottoActivityAttributes.ContentState(
                stateLabel: "Listening", conversationCount: 0, isPaused: false),
            staleDate: nil)
        activity = try? Activity.request(
            attributes: SottoActivityAttributes(startedAt: date), content: content)
    }

    func update(stateLabel: String, conversationCount: Int, isPaused: Bool) {
        guard let activity else { return }
        let content = ActivityContent(
            state: SottoActivityAttributes.ContentState(
                stateLabel: stateLabel, conversationCount: conversationCount, isPaused: isPaused),
            staleDate: nil)
        Task { await activity.update(content) }
    }

    func sessionEnded() {
        guard let activity else { return }
        self.activity = nil
        let content = ActivityContent(
            state: SottoActivityAttributes.ContentState(
                stateLabel: "Stopped", conversationCount: 0, isPaused: true),
            staleDate: nil)
        Task { await activity.end(content, dismissalPolicy: .immediate) }
    }
}

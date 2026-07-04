import Foundation
import UserNotifications

/// SPEC "Interruption handling": the fallback notification is scheduled on `.began` — a
/// matching `.ended` is NOT guaranteed — and cancelled if resume happens first.
protocol NotificationScheduling: Sendable {
    func requestAuthorizationIfNeeded() async
    func schedulePausedNotification() async
    func cancelPausedNotification() async
}

struct UserNotificationScheduler: NotificationScheduling {
    private static let pausedIdentifier = "sotto.paused"

    func requestAuthorizationIfNeeded() async {
        // Provisional: delivered quietly, no permission prompt (SPEC onboarding defers the
        // full prompt decision to M6; provisional keeps the fallback path working today).
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .provisional])
    }

    func schedulePausedNotification() async {
        let content = UNMutableNotificationContent()
        content.title = "Sotto was paused"
        content.body = "Listening stopped for a call or Siri. Tap to resume."
        let request = UNNotificationRequest(
            identifier: Self.pausedIdentifier, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    func cancelPausedNotification() async {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.pausedIdentifier])
        center.removeDeliveredNotifications(withIdentifiers: [Self.pausedIdentifier])
    }
}

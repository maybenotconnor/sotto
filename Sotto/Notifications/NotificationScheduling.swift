import Foundation
import UserNotifications

/// SPEC "Interruption handling": the fallback notification is scheduled on `.began` — a
/// matching `.ended` is NOT guaranteed — and cancelled if resume happens first.
protocol NotificationScheduling: Sendable {
    func requestAuthorizationIfNeeded() async
    func schedulePausedNotification() async
    func cancelPausedNotification() async
    /// M12: the Omi dropped and the pipeline rolled over to the iPhone mic automatically —
    /// recording continues, but the user should know capture quality may have changed.
    func scheduleSourceFallbackNotification() async
    /// M12: the Omi dropped AND the iPhone mic could not start — nothing is capturing.
    func scheduleCaptureUnavailableNotification() async
    /// M12: the Omi's reported battery level is low.
    func scheduleOmiLowBatteryNotification(level: Int) async
}

struct UserNotificationScheduler: NotificationScheduling {
    private static let pausedIdentifier = "sotto.paused"
    private static let sourceFallbackIdentifier = "sotto.sourceFallback"
    private static let captureUnavailableIdentifier = "sotto.captureUnavailable"
    private static let omiLowBatteryIdentifier = "sotto.omiLowBattery"

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

    func scheduleSourceFallbackNotification() async {
        let content = UNMutableNotificationContent()
        content.title = "Omi disconnected"
        content.body = "Recording continues on the iPhone microphone — audio may be muffled if the phone is in a pocket."
        let request = UNNotificationRequest(
            identifier: Self.sourceFallbackIdentifier, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    func scheduleCaptureUnavailableNotification() async {
        let content = UNMutableNotificationContent()
        content.title = "Recording stopped"
        content.body = "The Omi disconnected and the iPhone microphone could not start. Open Sotto to resume."
        let request = UNNotificationRequest(
            identifier: Self.captureUnavailableIdentifier, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    func scheduleOmiLowBatteryNotification(level: Int) async {
        let content = UNMutableNotificationContent()
        content.title = "Omi battery low"
        content.body = "About \(level)% left — charge it soon to keep recording."
        let request = UNNotificationRequest(
            identifier: Self.omiLowBatteryIdentifier, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}

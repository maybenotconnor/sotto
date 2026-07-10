import Foundation
import UserNotifications

/// SPEC "Interruption handling": the fallback notification is scheduled on `.began` — a
/// matching `.ended` is NOT guaranteed — and cancelled if resume happens first.
protocol NotificationScheduling: Sendable {
    func requestAuthorizationIfNeeded() async
    func schedulePausedNotification() async
    func cancelPausedNotification() async
    /// M12: the wearable dropped and the pipeline rolled over to the iPhone mic
    /// automatically — recording continues, but the user should know capture quality may
    /// have changed. `deviceName` is the wearable family's display name ("Omi").
    func scheduleSourceFallbackNotification(deviceName: String) async
    /// M12: the wearable dropped AND the iPhone mic could not start — nothing is capturing.
    func scheduleCaptureUnavailableNotification(deviceName: String) async
    /// M12: the wearable's reported battery level is low.
    func scheduleLowBatteryNotification(deviceName: String, level: Int) async
}

struct UserNotificationScheduler: NotificationScheduling {
    private static let pausedIdentifier = "sotto.paused"
    private static let sourceFallbackIdentifier = "sotto.sourceFallback"
    private static let captureUnavailableIdentifier = "sotto.captureUnavailable"
    // Identifier value predates the seam generalization; it's a dedup key, not copy —
    // changing it would orphan pending notifications.
    private static let lowBatteryIdentifier = "sotto.omiLowBattery"

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

    func scheduleSourceFallbackNotification(deviceName: String) async {
        let content = UNMutableNotificationContent()
        content.title = "\(deviceName) disconnected"
        content.body = "Recording continues on the iPhone microphone — audio may be muffled if the phone is in a pocket."
        let request = UNNotificationRequest(
            identifier: Self.sourceFallbackIdentifier, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    func scheduleCaptureUnavailableNotification(deviceName: String) async {
        let content = UNMutableNotificationContent()
        content.title = "Recording stopped"
        content.body = "The \(deviceName) disconnected and the iPhone microphone could not start. Open Sotto to resume."
        let request = UNNotificationRequest(
            identifier: Self.captureUnavailableIdentifier, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    func scheduleLowBatteryNotification(deviceName: String, level: Int) async {
        let content = UNMutableNotificationContent()
        content.title = "\(deviceName) battery low"
        content.body = "About \(level)% left — charge it soon to keep recording."
        let request = UNNotificationRequest(
            identifier: Self.lowBatteryIdentifier, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}

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
    /// M12 → redesign spec §3: the wearable is gone AND the iPhone mic could not start —
    /// nothing is capturing. Scheduled with `delay` (30 s: only persistent gaps alert)
    /// and cancelled by `cancelCaptureUnavailableNotification` on recovery or stop.
    func scheduleCaptureUnavailableNotification(deviceName: String, delay: TimeInterval) async
    func cancelCaptureUnavailableNotification() async
    /// M12: the wearable's reported battery level is low.
    func scheduleLowBatteryNotification(deviceName: String, level: Int) async
    /// 2026-08-04 incident: the app is being terminated (force-quit from the app switcher,
    /// system shutdown) while capture is live. Delivered immediately — this is the last
    /// code Sotto runs, and a force-quit app is barred from BLE state restoration, so
    /// there is no later moment to notify from.
    func scheduleClosedWhileRecordingNotification() async
}

struct UserNotificationScheduler: NotificationScheduling {
    private static let pausedIdentifier = "sotto.paused"
    private static let sourceFallbackIdentifier = "sotto.sourceFallback"
    private static let captureUnavailableIdentifier = "sotto.captureUnavailable"
    // Identifier value predates the seam generalization; it's a dedup key, not copy —
    // changing it would orphan pending notifications.
    private static let lowBatteryIdentifier = "sotto.omiLowBattery"
    private static let closedWhileRecordingIdentifier = "sotto.closedWhileRecording"

    func requestAuthorizationIfNeeded() async {
        // Full [.alert, .sound], not provisional (redesign spec §3): the "Recording
        // stopped" alert must always deliver loudly; provisional-quiet delivery is why
        // it was historically missed. Called from the foreground only (pipeline gates).
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])
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

    func scheduleCaptureUnavailableNotification(deviceName: String, delay: TimeInterval) async {
        let content = UNMutableNotificationContent()
        content.title = "Recording stopped"
        content.body = "The \(deviceName) disconnected and the iPhone microphone could not start. Open Sotto to resume."
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: Self.captureUnavailableIdentifier, content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false))
        try? await UNUserNotificationCenter.current().add(request)
    }

    func cancelCaptureUnavailableNotification() async {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.captureUnavailableIdentifier])
        center.removeDeliveredNotifications(withIdentifiers: [Self.captureUnavailableIdentifier])
    }

    func scheduleClosedWhileRecordingNotification() async {
        let content = UNMutableNotificationContent()
        content.title = "Sotto was closed"
        content.body = "Recording was still running and has stopped. Reopen Sotto to start again."
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: Self.closedWhileRecordingIdentifier, content: content, trigger: nil)
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

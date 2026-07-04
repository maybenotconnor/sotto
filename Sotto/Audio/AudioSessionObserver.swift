import AVFoundation
import Foundation
import UIKit

/// Wraps UIApplication background-task begin/end (SPEC: after audio stops, ~30 s before
/// suspension — wrap the `.began` handler in a background task).
protocol BackgroundTasking: Sendable {
    func begin() -> Int
    func end(_ identifier: Int)
}

struct UIKitBackgroundTasks: BackgroundTasking {
    func begin() -> Int {
        // Callers (AudioSessionObserver) only ever invoke this from the .main-queue
        // notification callback, already MainActor-isolated at runtime; `assumeIsolated`
        // documents that invariant to the compiler since the protocol requirement itself
        // must stay nonisolated/synchronous to satisfy `BackgroundTasking`.
        MainActor.assumeIsolated {
            UIApplication.shared.beginBackgroundTask(withName: "sotto.interruption").rawValue
        }
    }

    func end(_ identifier: Int) {
        MainActor.assumeIsolated {
            UIApplication.shared.endBackgroundTask(UIBackgroundTaskIdentifier(rawValue: identifier))
        }
    }
}

/// Registers for the three session notifications (SPEC "Interruption handling") and
/// forwards them as async callbacks. Owns no policy — the pipeline decides what to do.
@MainActor
final class AudioSessionObserver {
    private let center: NotificationCenter
    private let backgroundTasks: any BackgroundTasking
    // nonisolated(unsafe): `NSObjectProtocol` tokens aren't Sendable, but deinit is always
    // nonisolated even for a @MainActor class — safe here because deinit only runs after
    // the last strong reference (and therefore all MainActor-isolated mutation) is gone.
    private nonisolated(unsafe) var tokens: [NSObjectProtocol] = []

    var onInterruptionBegan: (() async -> Void)?
    var onInterruptionEndedShouldResume: ((Bool) async -> Void)?
    var onRouteChangeDeviceUnavailable: (() async -> Void)?
    var onMediaServicesReset: (() async -> Void)?

    init(center: NotificationCenter = .default, backgroundTasks: any BackgroundTasking) {
        self.center = center
        self.backgroundTasks = backgroundTasks
    }

    func startObserving(session: AVAudioSession = .sharedInstance()) {
        tokens.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: session, queue: .main
        ) { [weak self] notification in
            guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            let shouldResume: Bool = {
                guard let optionsRaw =
                    notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
                else { return false }
                return AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
                    .contains(.shouldResume)
            }()
            MainActor.assumeIsolated {
                guard let self else { return }
                switch type {
                case .began:
                    let taskID = self.backgroundTasks.begin()
                    let handler = self.onInterruptionBegan
                    let tasks = self.backgroundTasks
                    Task {
                        await handler?()
                        tasks.end(taskID)
                    }
                case .ended:
                    let handler = self.onInterruptionEndedShouldResume
                    Task { await handler?(shouldResume) }
                @unknown default:
                    break
                }
            }
        })

        tokens.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: session, queue: .main
        ) { [weak self] notification in
            guard let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: raw),
                  reason == .oldDeviceUnavailable else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                let handler = self.onRouteChangeDeviceUnavailable
                Task { await handler?() }
            }
        })

        tokens.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let handler = self.onMediaServicesReset
                Task { await handler?() }
            }
        })
    }

    deinit {
        for token in tokens {
            center.removeObserver(token)
        }
    }
}

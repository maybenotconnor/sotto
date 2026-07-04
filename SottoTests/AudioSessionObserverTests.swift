import AVFoundation
import Foundation
import Testing
@testable import Sotto

@MainActor
struct AudioSessionObserverTests {
    final class FakeBackgroundTasks: BackgroundTasking, @unchecked Sendable {
        // Mutated only on the MainActor in these tests.
        private(set) var begun = 0
        private(set) var ended: [Int] = []
        func begin() -> Int { begun += 1; return begun }
        func end(_ identifier: Int) { ended.append(identifier) }
    }

    private func makeObserver() -> (AudioSessionObserver, NotificationCenter, FakeBackgroundTasks) {
        let center = NotificationCenter()
        let tasks = FakeBackgroundTasks()
        let observer = AudioSessionObserver(center: center, backgroundTasks: tasks)
        return (observer, center, tasks)
    }

    @Test func interruptionBeganFiresCallbackInsideBackgroundTask() async throws {
        let (observer, center, tasks) = makeObserver()
        var beganCalls = 0
        observer.onInterruptionBegan = { beganCalls += 1 }
        observer.startObserving(session: AVAudioSession.sharedInstance())

        center.post(
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            userInfo: [AVAudioSessionInterruptionTypeKey:
                AVAudioSession.InterruptionType.began.rawValue])
        try await Task.sleep(for: .milliseconds(100))   // handler hops through a Task

        #expect(beganCalls == 1)
        #expect(tasks.begun == 1)
        #expect(tasks.ended == [1])                     // task ended after the handler finished
    }

    @Test func interruptionEndedForwardsShouldResume() async throws {
        let (observer, center, _) = makeObserver()
        var received: [Bool] = []
        observer.onInterruptionEndedShouldResume = { received.append($0) }
        observer.startObserving(session: AVAudioSession.sharedInstance())

        center.post(
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            userInfo: [
                AVAudioSessionInterruptionTypeKey:
                    AVAudioSession.InterruptionType.ended.rawValue,
                AVAudioSessionInterruptionOptionKey:
                    AVAudioSession.InterruptionOptions.shouldResume.rawValue,
            ])
        try await Task.sleep(for: .milliseconds(100))

        #expect(received == [true])
    }

    @Test func oldDeviceUnavailableRouteChangeFires() async throws {
        let (observer, center, _) = makeObserver()
        var calls = 0
        observer.onRouteChangeDeviceUnavailable = { calls += 1 }
        observer.startObserving(session: AVAudioSession.sharedInstance())

        center.post(
            name: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            userInfo: [AVAudioSessionRouteChangeReasonKey:
                AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue])
        try await Task.sleep(for: .milliseconds(100))
        #expect(calls == 1)

        // Other reasons are ignored:
        center.post(
            name: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            userInfo: [AVAudioSessionRouteChangeReasonKey:
                AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue])
        try await Task.sleep(for: .milliseconds(100))
        #expect(calls == 1)
    }

    @Test func mediaServicesResetFires() async throws {
        let (observer, center, _) = makeObserver()
        var calls = 0
        observer.onMediaServicesReset = { calls += 1 }
        observer.startObserving(session: AVAudioSession.sharedInstance())

        center.post(
            name: AVAudioSession.mediaServicesWereResetNotification,
            object: AVAudioSession.sharedInstance())
        try await Task.sleep(for: .milliseconds(100))
        #expect(calls == 1)
    }
}

import AppIntents
import Testing
@testable import Sotto

@MainActor
struct ToggleListeningIntentTests {
    /// Device-log-proven (2026-07-23): with AudioRecordingIntent alone, iOS ran perform()
    /// in the SottoWidgets extension process — where IntentHandlers is deliberately empty —
    /// so every lock-screen tap was a sub-millisecond no-op. AudioRecordingIntent
    /// (`: SystemIntent`) only grants the background-mic capability; app-process routing
    /// comes solely from the LiveActivityIntent conformance this test pins.
    @Test func intentRoutesToAppProcessViaLiveActivityIntentConformance() {
        #expect(ToggleListeningIntent() as Any is any LiveActivityIntent)
    }
}

import Foundation
import Testing
@testable import Sotto

struct LiveActivityWiringTests {
    @Test func contentStateRoundTripsThroughCodable() throws {
        let state = SottoActivityAttributes.ContentState(
            phase: .recording, conversationCount: 3)
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(SottoActivityAttributes.ContentState.self, from: data)
        #expect(decoded == state)
    }

    @Test func pausedPhasesReportPaused() {
        #expect(SottoActivityAttributes.Phase.pausedByUser.isPaused)
        #expect(SottoActivityAttributes.Phase.pausedBySystem.isPaused)
        #expect(!SottoActivityAttributes.Phase.listening.isPaused)
        #expect(!SottoActivityAttributes.Phase.recording.isPaused)
    }
}

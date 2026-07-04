import Foundation
import Testing
@testable import Sotto

struct LiveActivityWiringTests {
    @Test func contentStateRoundTripsThroughCodable() throws {
        let state = SottoActivityAttributes.ContentState(
            stateLabel: "Recording", conversationCount: 3, isPaused: false)
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(SottoActivityAttributes.ContentState.self, from: data)
        #expect(decoded == state)
    }
}

import Testing
@testable import Sotto

@MainActor
struct AppModelTests {
    @Test func intentHandlerIsRegisteredAtConstruction() async throws {
        let model = AppModel()
        _ = model
        #expect(IntentHandlers.shared.toggle != nil)   // cold background launch can toggle
    }
}

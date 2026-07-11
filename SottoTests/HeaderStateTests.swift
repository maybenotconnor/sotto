import Foundation
import Testing
@testable import Sotto

struct HeaderStateTests {
    @Test func openSegmentTakesPriorityOverStatus() {
        let segmentStart = Date(timeIntervalSince1970: 100)
        let state = HeaderState(
            segmentStart: segmentStart, status: .listening,
            haltReason: nil, sessionStart: Date(timeIntervalSince1970: 50))
        #expect(state == .segmentOpen(start: segmentStart))
        #expect(state.label == "Recording…")
        #expect(state.timerStart == segmentStart)
    }

    @Test func statusMapsToState() {
        #expect(HeaderState(segmentStart: nil, status: .idle, haltReason: nil, sessionStart: nil) == .idle)
        #expect(HeaderState(segmentStart: nil, status: .starting, haltReason: nil, sessionStart: nil) == .starting)
        #expect(HeaderState(segmentStart: nil, status: .interrupted, haltReason: .userPause, sessionStart: nil)
            == .interrupted(.userPause))
        let sessionStart = Date(timeIntervalSince1970: 5)
        for status in [ListeningPipeline.Status.listening, .recording, .silence] {
            #expect(HeaderState(segmentStart: nil, status: status, haltReason: nil, sessionStart: sessionStart)
                == .listening(sessionStart: sessionStart))
        }
    }

    @Test func pausedLabelsMatchHaltReason() {
        #expect(HeaderState.interrupted(.userPause).label == "Paused by you")
        #expect(HeaderState.interrupted(.systemInterruption).label == "Paused — call")
        #expect(HeaderState.interrupted(nil).label == "Paused — call")
    }

    @Test func oneTimerAtATime() {
        let sessionStart = Date(timeIntervalSince1970: 5)
        #expect(HeaderState.listening(sessionStart: sessionStart).timerStart == sessionStart)
        #expect(HeaderState.idle.timerStart == nil)
        #expect(HeaderState.starting.timerStart == nil)
        #expect(HeaderState.interrupted(nil).timerStart == nil)
    }

    @Test func subtitleOnlyWhenIdle() {
        #expect(HeaderState.idle.subtitle == "Ready to listen")
        #expect(HeaderState.starting.subtitle == nil)
        #expect(HeaderState.listening(sessionStart: nil).subtitle == nil)
        #expect(HeaderState.interrupted(.userPause).subtitle == nil)
        #expect(HeaderState.segmentOpen(start: Date(timeIntervalSince1970: 0)).subtitle == nil)
    }
}

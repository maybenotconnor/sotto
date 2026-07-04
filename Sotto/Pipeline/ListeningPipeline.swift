import Foundation
import Observation

/// M1 glue: pumps AudioChunks from the source through the pre-roll buffer and VAD,
/// and publishes status for SwiftUI. M2 replaces `Status` with the five-state
/// RecorderStateMachine; the wiring pattern here carries over.
///
/// Transitions are mutually exclusive: a `stop()` arriving while a `start()` is in
/// flight is queued and honored the moment that start completes; a `start()` arriving
/// during any in-flight transition is a no-op.
@MainActor
@Observable
final class ListeningPipeline {
    enum Status: Equatable {
        case idle
        case listening
        case speechActive
    }

    private(set) var status: Status = .idle
    private(set) var eventLog: [String] = []

    private let source: any AudioSource
    private let detector: any SpeechDetecting
    private var preRoll: PreRollBuffer
    private var pumpTask: Task<Void, Never>?
    private var isTransitioning = false
    private var stopRequestedDuringTransition = false

    init(source: any AudioSource, detector: any SpeechDetecting, preRollSamples: Int = 16_000) {
        self.source = source
        self.detector = detector
        self.preRoll = PreRollBuffer(capacity: preRollSamples)
    }

    func start() async {
        guard status == .idle, !isTransitioning else { return }
        isTransitioning = true
        status = .listening
        var started = false
        do {
            let stream = try await source.start()
            eventLog.append("Listening…")
            pumpTask = Task {
                for await chunk in stream {
                    await self.handle(chunk)
                }
            }
            started = true
        } catch {
            status = .idle
            eventLog.append("Start failed: \(error)")
        }
        isTransitioning = false
        let stopWasRequested = stopRequestedDuringTransition
        stopRequestedDuringTransition = false
        if started && stopWasRequested {
            await stop()   // honor the stop that arrived mid-start
        }
    }

    func stop() async {
        if isTransitioning {
            stopRequestedDuringTransition = true
            return
        }
        guard status != .idle else { return }
        isTransitioning = true
        await source.stop()          // finish the stream: no new chunks after this
        await pumpTask?.value        // drain chunks already in flight to quiescence
        pumpTask = nil
        await detector.reset()
        preRoll.removeAll()
        status = .idle
        eventLog.append("Stopped")
        isTransitioning = false
        stopRequestedDuringTransition = false
    }

    /// Test hook: waits for the pump task to finish draining a closed stream.
    func waitUntilDrained() async {
        await pumpTask?.value
    }

    func preRollSnapshot() -> [Float] {
        preRoll.snapshot()
    }

    private func handle(_ chunk: AudioChunk) async {
        preRoll.append(chunk.samples)
        do {
            guard let event = try await detector.process(chunk) else { return }
            switch event {
            case .speechStart:
                status = .speechActive
                eventLog.append("Speech started")
            case .speechEnd:
                status = .listening
                eventLog.append("Speech ended")
            }
        } catch {
            eventLog.append("VAD error: \(error)")
        }
    }
}

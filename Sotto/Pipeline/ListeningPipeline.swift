import Foundation
import Observation

/// M1 glue: pumps AudioChunks from the source through the pre-roll buffer and VAD,
/// and publishes status for SwiftUI. M2 replaces `Status` with the five-state
/// RecorderStateMachine; the wiring pattern here carries over.
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

    init(source: any AudioSource, detector: any SpeechDetecting, preRollSamples: Int = 16_000) {
        self.source = source
        self.detector = detector
        self.preRoll = PreRollBuffer(capacity: preRollSamples)
    }

    func start() async {
        guard status == .idle else { return }
        status = .listening   // claim before the first await so reentrant starts bounce off the guard
        do {
            let stream = try await source.start()
            eventLog.append("Listening…")
            pumpTask = Task {
                for await chunk in stream {
                    await self.handle(chunk)
                }
            }
        } catch {
            status = .idle
            eventLog.append("Start failed: \(error)")
        }
    }

    func stop() async {
        guard status != .idle else { return }
        await source.stop()          // finish the stream: no new chunks after this
        await pumpTask?.value        // drain chunks already in flight to quiescence
        pumpTask = nil
        await detector.reset()
        preRoll.removeAll()
        status = .idle
        eventLog.append("Stopped")
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

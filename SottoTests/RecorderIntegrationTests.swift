import AVFoundation
import Foundation
import Synchronization
import Testing
@testable import Sotto

struct RecorderIntegrationTests {
    @Test func syntheticSpeechProducesRealM4ASegment() async throws {
        let modelURL = try #require(Bundle.main.url(
            forResource: SileroSpeechDetector.modelResourceName, withExtension: "mlmodelc"))
        let detector = try SileroSpeechDetector(modelURL: modelURL, threshold: 0.3)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecorderIntegration-\(UUID().uuidString)")
        let store = SegmentStore(rootDirectory: root)

        var config = RecorderConfig()
        config.silenceTimeout = 1.0
        config.minSegmentSpeechDuration = 0.5
        let machine = RecorderStateMachine(
            detector: detector,
            writerFactory: CAFSegmentWriterFactory(store: store),
            store: store, config: config)

        let received = Mutex<[FinalizedSegment]>([])
        let service = FakeTranscriptionService(text: "integration transcript")
        let queue = TranscriptionQueue(
            storeURL: root.appendingPathComponent("jobs.json"), service: service, rootDirectory: root)
        await machine.setSegmentHandler { segment in
            received.withLock { $0.append(segment) }
            // Mirrors AppModel's wiring: enqueue + drain into the real queue rather than
            // hand-rolling the transcode/transcribe/write steps in the test.
            Task {
                await queue.enqueue(segment)
                await queue.drain()
            }
        }

        _ = await machine.beginListening()

        // ~2 s of speech-like audio in 4096-sample chunks (generator per the detector test):
        let speech = makeSpeechLikeSignal(seconds: 2.0)
        var last = RecorderSnapshot(state: .idle, finalizedCount: 0, lastEvent: nil)
        for start in stride(from: 0, to: speech.count - VADConstants.chunkSize, by: VADConstants.chunkSize) {
            let chunk = Array(speech[start..<start + VADConstants.chunkSize])
            last = await machine.process(AudioChunk(samples: chunk, hostTime: 0))
        }
        #expect(last.state == .recording || last.state == .silence)

        // Silence until finalize: the VAD's own ~0.75 s hysteresis must elapse BEFORE the
        // machine's 1 s timeout even starts counting, so allow ~3 s of zero chunks:
        for _ in 0..<12 {
            last = await machine.process(AudioChunk(
                samples: [Float](repeating: 0, count: VADConstants.chunkSize), hostTime: 0))
        }

        #expect(last.finalizedCount == 1)
        #expect(last.state == .listening)

        let segments = received.withLock { $0 }
        #expect(segments.count == 1)
        let segment = segments[0]

        // The segment handler's enqueue+drain runs in a detached Task (mirroring AppModel's
        // wiring), so poll briefly for the job to reach a terminal state rather than assume
        // synchronous completion.
        var job: TranscriptionJob?
        for _ in 0..<200 {
            job = await queue.jobs.first
            if let state = job?.state, state != .pending { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(job?.state == .done)
        #expect(await service.calls == 1)

        // The queue transcodes to the segment's own m4a destination and deletes its CAF:
        #expect(FileManager.default.fileExists(atPath: segment.m4aURL.path))
        #expect(!FileManager.default.fileExists(atPath: segment.cafURL.path))
        let file = try AVAudioFile(forReading: segment.m4aURL)
        let duration = Double(file.length) / file.processingFormat.sampleRate
        #expect(duration > 2.0)   // speech + pre-roll + trailing silence

        // ... and writes the markdown transcript next to it.
        let md = segment.m4aURL.deletingPathExtension().appendingPathExtension("md")
        let transcript = try String(contentsOf: md, encoding: .utf8)
        #expect(transcript.contains("integration transcript"))
    }
}

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
        await machine.setSegmentHandler { segment in
            received.withLock { $0.append(segment) }
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

        // Segment close is fast now: CAF is on disk, m4a doesn't exist yet (M4 Task 1 —
        // transcode is deferred to the transcription queue, arriving in Task 3).
        #expect(FileManager.default.fileExists(atPath: segment.cafURL.path))
        #expect(!FileManager.default.fileExists(atPath: segment.m4aURL.path))

        // Do the queue's job manually here so the rest of the assertions still exercise a
        // real transcode:
        try CAFSegmentWriter.transcodeToM4A(caf: segment.cafURL, m4a: segment.m4aURL)

        let m4as = try FileManager.default.subpathsOfDirectory(atPath: root.path)
            .filter { $0.hasSuffix(".m4a") }
        #expect(m4as.count == 1)
        let file = try AVAudioFile(forReading: root.appendingPathComponent(m4as[0]))
        let duration = Double(file.length) / file.processingFormat.sampleRate
        #expect(duration > 2.0)   // speech + pre-roll + trailing silence

        // The queue owns CAF deletion from Task 3 on; simulate that here before asserting
        // no CAF is left behind.
        try FileManager.default.removeItem(at: segment.cafURL)
        let cafs = try FileManager.default.subpathsOfDirectory(atPath: root.path)
            .filter { $0.hasSuffix(".caf") }
        #expect(cafs.isEmpty)
    }
}

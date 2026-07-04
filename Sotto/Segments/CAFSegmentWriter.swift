import AVFoundation
import Foundation

/// Crash-safe segment writer (SPEC "Recording writer", option 2): capture is written as
/// 16 kHz mono Int16 PCM **CAF** — CAF is valid without finalization, so a process death
/// mid-segment loses nothing already flushed. `close()` just flushes and releases the
/// file handle — it is deliberately FAST; transcoding to AAC .m4a
/// (~0.36 MB/min at 48 kbps — the highest bit rate the AAC encoder's discrete-rate table
/// offers for 16 kHz mono; 64 kbps, the round-number target, isn't an available step)
/// and removing the CAF is the transcription queue's job (M4). The same transcode
/// salvages orphaned CAFs on launch.
final class CAFSegmentWriter: SegmentWriting {
    enum WriterError: Error {
        case bufferAllocationFailed
    }

    let cafURL: URL
    let m4aURL: URL
    private var file: AVAudioFile?
    private(set) var writtenSampleCount = 0

    init(cafURL: URL, m4aURL: URL) throws {
        self.cafURL = cafURL
        self.m4aURL = m4aURL
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Double(VADConstants.sampleRate),
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        // Write via a Float32 processing format; AVAudioFile converts to Int16 on disk.
        self.file = try AVAudioFile(
            forWriting: cafURL, settings: settings,
            commonFormat: .pcmFormatFloat32, interleaved: false)
        // Explicit per SPEC — must never become `.complete`, which breaks writes while locked.
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: cafURL.path)
    }

    func append(_ samples: [Float]) throws {
        guard let file, !samples.isEmpty else { return }
        // (empty append happens legitimately: segment rotation flushes an empty pre-roll;
        // AVAudioPCMBuffer with zero capacity would return nil and throw spuriously)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(samples.count))
        else {
            throw WriterError.bufferAllocationFailed
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { pointer in
            buffer.floatChannelData![0].update(from: pointer.baseAddress!, count: samples.count)
        }
        try file.write(from: buffer)
        writtenSampleCount += samples.count
    }

    func close() {
        file = nil   // AVAudioFile flushes and closes on release
    }

    func discard() {
        file = nil
        try? FileManager.default.removeItem(at: cafURL)
        try? FileManager.default.removeItem(at: m4aURL)
    }

    /// Also used by OrphanSalvager for CAFs left behind by an unclean shutdown.
    static func transcodeToM4A(caf: URL, m4a: URL) throws {
        let input = try AVAudioFile(forReading: caf)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: Double(VADConstants.sampleRate),
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 48_000,
        ]
        let output = try AVAudioFile(forWriting: m4a, settings: settings)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 32_768)
        else {
            throw WriterError.bufferAllocationFailed
        }
        while input.framePosition < input.length {
            try input.read(into: buffer)
            if buffer.frameLength == 0 { break }
            try output.write(from: buffer)
        }
        // Explicit per SPEC — must never become `.complete`, which breaks reads while
        // locked. Single owner of this attribute for the m4a: both the queue's deferred
        // transcode and OrphanSalvager's launch-time salvage transcode go through here.
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: m4a.path)
    }
}

struct CAFSegmentWriterFactory: SegmentWriterFactory {
    let store: SegmentStore

    func makeWriter(startDate: Date) throws -> any SegmentWriting {
        let paths = try store.pathsForSegment(startingAt: startDate)
        return try CAFSegmentWriter(cafURL: paths.cafURL, m4aURL: paths.m4aURL)
    }
}

import AVFoundation
import os

/// Converts hardware-format tap buffers to the pipeline format: 16 kHz mono Float32.
/// One instance per tap installation (AVAudioConverter carries resampler state);
/// rebuild it on route changes when the hardware format shifts (M3).
///
/// Instances are confined to the audio tap thread behind `TapProcessor`'s `Mutex`
/// (see `PhoneMicAudioSource.swift`), which serializes all access and makes this
/// genuinely thread-safe despite wrapping a non-Sendable `AVAudioConverter`.
/// `@unchecked` because the compiler cannot see that confinement.
final class FormatConverter: @unchecked Sendable {
    static let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    private let logger = Logger(subsystem: "com.decanlys.Sotto", category: "FormatConverter")

    private let converter: AVAudioConverter
    private let ratio: Double
    private var scratch: AVAudioPCMBuffer?

    init?(inputFormat: AVAudioFormat) {
        // Defense-in-depth: a 0 Hz / 0-channel "format" is a documented AVAudioEngine
        // degenerate state when no valid input route exists; without this guard the
        // ratio below becomes non-finite and the first convert() traps on the audio thread.
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
              let converter = AVAudioConverter(from: inputFormat, to: Self.targetFormat)
        else {
            return nil
        }
        self.converter = converter
        self.ratio = Self.targetFormat.sampleRate / inputFormat.sampleRate
    }

    /// Synchronously converts one tap buffer, copying samples out — the returned array
    /// owns its memory, so both the tap buffer and the reused scratch buffer are free
    /// to be recycled.
    func convert(_ buffer: AVAudioPCMBuffer) -> [Float] {
        let needed = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        if scratch == nil || scratch!.frameCapacity < needed {
            // Rare: first call, or a larger-than-ever tap buffer — never steady-state.
            // Allocating per callback on the realtime audio thread risks priority
            // inversion; reuse keeps the hot path allocation-free.
            scratch = AVAudioPCMBuffer(pcmFormat: Self.targetFormat, frameCapacity: max(needed, 4096))
        }
        guard let output = scratch else {
            logger.error("Failed to allocate conversion scratch buffer (\(needed) frames)")
            return []
        }
        output.frameLength = 0

        // The converter invokes the input block synchronously on the calling thread during
        // `convert`, so these captures never actually cross threads (block is marked @Sendable).
        nonisolated(unsafe) var consumed = false
        nonisolated(unsafe) let inputBuffer = buffer
        var conversionError: NSError?
        converter.convert(to: output, error: &conversionError) { _, outStatus in
            if consumed {
                // .noDataNow (not .endOfStream) keeps the resampler primed for the next tap buffer.
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return inputBuffer
        }

        guard conversionError == nil, let channelData = output.floatChannelData else {
            logger.error("Audio conversion failed: \(conversionError?.localizedDescription ?? "no channel data")")
            return []
        }
        return Array(UnsafeBufferPointer(start: channelData[0], count: Int(output.frameLength)))
    }
}

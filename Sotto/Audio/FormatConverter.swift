import AVFoundation

/// Converts hardware-format tap buffers to the pipeline format: 16 kHz mono Float32.
/// One instance per tap installation (AVAudioConverter carries resampler state);
/// rebuild it on route changes when the hardware format shifts (M3).
final class FormatConverter {
    static let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    private let converter: AVAudioConverter
    private let ratio: Double

    init?(inputFormat: AVAudioFormat) {
        guard let converter = AVAudioConverter(from: inputFormat, to: Self.targetFormat) else {
            return nil
        }
        self.converter = converter
        self.ratio = Self.targetFormat.sampleRate / inputFormat.sampleRate
    }

    /// Synchronously converts one tap buffer, copying samples out — the returned array
    /// owns its memory, so the tap buffer is free to be recycled by the engine.
    func convert(_ buffer: AVAudioPCMBuffer) -> [Float] {
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: Self.targetFormat, frameCapacity: capacity) else {
            return []
        }

        var consumed = false
        var conversionError: NSError?
        converter.convert(to: output, error: &conversionError) { _, outStatus in
            if consumed {
                // .noDataNow (not .endOfStream) keeps the resampler primed for the next tap buffer.
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        guard conversionError == nil, let channelData = output.floatChannelData else {
            return []
        }
        return Array(UnsafeBufferPointer(start: channelData[0], count: Int(output.frameLength)))
    }
}

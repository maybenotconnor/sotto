import AVFoundation
import Testing
@testable import Sotto

struct FormatConverterTests {
    @Test func downsamplesStereo48kToMono16k() throws {
        let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
        let converter = try #require(FormatConverter(inputFormat: inputFormat))

        let frames: AVAudioFrameCount = 4800   // 100 ms @ 48 kHz → expect ~1600 out per pass
        let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<2 {
            let data = buffer.floatChannelData![channel]
            for i in 0..<Int(frames) {
                data[i] = sinf(2 * .pi * 440 * Float(i) / 48_000)
            }
        }

        // Rate converters hold back priming samples; assert over two passes.
        let total = converter.convert(buffer).count + converter.convert(buffer).count
        #expect(abs(total - 3200) <= 256)
    }

    @Test func constructsForStandardPCMInputs() {
        let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 1, interleaved: false)!
        #expect(FormatConverter(inputFormat: inputFormat) != nil)
    }
}

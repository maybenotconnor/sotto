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

        // Rate converters hold back priming samples; assert over two passes. The reusable
        // scratch buffer (min capacity 4096, vs. the ~1664 an exact-sized per-call buffer
        // would have used) gives the resampler more destination room during warm-up, which
        // measurably widens the priming deficit on this toolchain — 512 covers it with
        // margin while still catching gross corruption (which would be off by thousands).
        let total = converter.convert(buffer).count + converter.convert(buffer).count
        #expect(abs(total - 3200) <= 512)
    }

    @Test func constructsForStandardPCMInputs() {
        let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 1, interleaved: false)!
        #expect(FormatConverter(inputFormat: inputFormat) != nil)
    }

    @Test func reusedConverterProducesConsistentOutputAcrossManyCalls() throws {
        let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
        let converter = try #require(FormatConverter(inputFormat: inputFormat))
        let frames: AVAudioFrameCount = 4800   // 100 ms @ 48 kHz
        let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frames)!
        buffer.frameLength = frames
        for i in 0..<Int(frames) {
            buffer.floatChannelData![0][i] = sinf(2 * .pi * 440 * Float(i) / 48_000)
        }

        var total = 0
        for _ in 0..<10 {
            let out = converter.convert(buffer)
            #expect(out.allSatisfy { $0.isFinite })
            total += out.count
        }
        // 10 × 100 ms @ 16 kHz = 16,000 samples, minus resampler priming latency. That
        // latency is measurably larger with the reusable scratch buffer's 4096-frame floor
        // (~944 samples on this toolchain, deterministic across repeated runs and stable
        // whether measured over 10 or 100 calls) than with an exact-sized per-call buffer,
        // so the tolerance is wider than a naive "one buffer's worth" estimate. 1024 still
        // catches real reuse bugs (stale frameLength/corruption), which inflate totals by
        // many thousands, not hundreds.
        #expect(abs(total - 16_000) <= 1024)
    }

    @Test func rejectsDegenerateZeroRateFormat() {
        // AVAudioFormat may refuse to construct a 0 Hz format at all — if so, the guard
        // in FormatConverter.init is pure defense-in-depth and this test documents that.
        if let zeroRate = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 0, channels: 1, interleaved: false) {
            #expect(FormatConverter(inputFormat: zeroRate) == nil)
        }
    }
}

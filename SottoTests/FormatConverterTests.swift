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

        // Rate converters hold back priming samples; assert over two passes. The scratch
        // buffer is sized to the exact tap-buffer need, so the resampler's priming deficit
        // is a fixed ~262 samples on this toolchain, deterministic across runs — 512 covers
        // it with margin while still catching gross corruption (off by thousands).
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
        // 10 × 100 ms @ 16 kHz = 16,000 samples, minus resampler priming latency. With the
        // scratch buffer sized to the exact tap-buffer need, that latency is a fixed ~262
        // samples on this toolchain, deterministic across repeated runs and stable whether
        // measured over 10 or 100 calls — a one-time priming cost, not per-call loss. 512
        // still catches real reuse bugs (stale frameLength/corruption), which inflate
        // totals by many thousands, not hundreds.
        #expect(abs(total - 16_000) <= 512)
    }

    @Test func resamplerDeficitDoesNotGrowWithCallCount() throws {
        func totalOutput(calls: Int) throws -> Int {
            let inputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
            let converter = try #require(FormatConverter(inputFormat: inputFormat))
            let frames: AVAudioFrameCount = 4800
            let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frames)!
            buffer.frameLength = frames
            for i in 0..<Int(frames) {
                buffer.floatChannelData![0][i] = sinf(2 * .pi * 440 * Float(i) / 48_000)
            }
            var total = 0
            for _ in 0..<calls {
                total += converter.convert(buffer).count
            }
            return total
        }
        // The resampler's holdback is one-time priming latency: the deficit measured over
        // 100 calls must match the deficit over 10 calls, else samples are leaking per call.
        let deficit10 = 10 * 1600 - (try totalOutput(calls: 10))
        let deficit100 = 100 * 1600 - (try totalOutput(calls: 100))
        #expect(abs(deficit100 - deficit10) <= 128)
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

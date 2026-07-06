import AVFoundation
import Foundation
import Opus
import Testing
@testable import Sotto

struct OmiVendoredCodecTests {
    @Test func pcmCodecIsPassthrough() {
        let codec = OmiPcmCodec(sampleRate: 16_000)
        let input = Data([0x01, 0x02, 0x03, 0x04])
        #expect(codec.decode(data: input) == input)
    }

    @Test func muLawDecodesKnownValues() {
        let codec = OmiMuLawCodec(sampleRate: 16_000)
        // µ-law 0x00 → -32124, 0xFF → 0 (last table entry), per the vendored table.
        let decoded = codec.decode(data: Data([0x00, 0xFF]))
        let samples = decoded.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        #expect(samples == [-32124, 0])
    }

    @Test func opusRoundTripRecoversToneEnergy() throws {
        // Encode one 20 ms 16 kHz mono frame (320 samples) of a loud 440 Hz tone with
        // swift-opus, decode with OmiOpusCodec, and check the energy survived. Opus is
        // lossy — assert on RMS, not samples.
        // NOTE: if Opus.Encoder's API differs at this pin (check the swift-opus README /
        // Encoder.swift in the checked-out package), adapt THIS test only — the codec
        // under test only touches Decoder.
        let opusFormat = try #require(AVAudioFormat(
            opusPCMFormat: .int16, sampleRate: .opus16khz, channels: 1))
        let encoder = try Opus.Encoder(format: opusFormat)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: opusFormat, frameCapacity: 320))
        buffer.frameLength = 320
        let channel = try #require(buffer.int16ChannelData?[0])
        for i in 0..<320 {
            channel[i] = Int16(20_000 * sin(2 * .pi * 440 * Double(i) / 16_000))
        }
        var packet = Data(count: 1_500)
        let byteCount = try encoder.encode(buffer, to: &packet)
        let frame = packet.prefix(byteCount)

        let codec = try OmiOpusCodec(sampleRate: 16_000)
        let decoded = try codec.decode(data: Data(frame))
        let samples = decoded.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        #expect(samples.count >= 320)
        let rms = (samples.map { Double($0) * Double($0) }.reduce(0, +) / Double(samples.count))
            .squareRoot()
        #expect(rms > 2_000)   // loud tone in, non-silence out
    }
}

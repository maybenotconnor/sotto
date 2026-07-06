import Foundation
import Testing
@testable import Sotto

struct OmiAudioDecoderTests {
    @Test func pcm16FramesBecomeNormalizedFloats() throws {
        let decoder = try OmiAudioDecoder(codecValue: OmiConstants.codecPCM16at16kHz)
        // Int16 LE: 0, 16384 (0.5), -32768 (-1.0)
        let frame = Data([0x00, 0x00, 0x00, 0x40, 0x00, 0x80])
        let floats = decoder.decode(.frame(frame))
        #expect(floats.count == 3)
        #expect(abs(floats[0] - 0.0) < 0.0001)
        #expect(abs(floats[1] - 0.5) < 0.0001)
        #expect(abs(floats[2] - (-1.0)) < 0.0001)
    }

    @Test func muLawFramesDecodeThroughTable() throws {
        let decoder = try OmiAudioDecoder(codecValue: OmiConstants.codecMuLawAt16kHz)
        let floats = decoder.decode(.frame(Data([0x00])))   // µ-law 0x00 → -32124
        #expect(floats.count == 1)
        #expect(abs(floats[0] - (-32124.0 / 32768.0)) < 0.0001)
    }

    @Test func gapsBecomeSilenceFill() throws {
        let decoder = try OmiAudioDecoder(codecValue: OmiConstants.codecPCM16at16kHz)
        let floats = decoder.decode(.gap(missingPackets: 2))
        #expect(floats.count == 2 * OmiConstants.samplesPerFrame)
        #expect(floats.allSatisfy { $0 == 0 })
    }

    @Test func eightKilohertzCodecsAreRejected() {
        for value in [OmiConstants.codecPCM16at8kHz, OmiConstants.codecMuLawAt8kHz, UInt8(99)] {
            #expect(throws: OmiAudioDecoder.DecoderError.unsupportedCodec(value)) {
                _ = try OmiAudioDecoder(codecValue: value)
            }
        }
    }

    @Test func corruptOpusFrameYieldsSilenceNotCrash() throws {
        let decoder = try OmiAudioDecoder(codecValue: OmiConstants.codecOpusAt16kHz)
        let floats = decoder.decode(.frame(Data([0xDE, 0xAD, 0xBE])))
        // Undecodable frame → one frame of silence (same recovery as a gap).
        #expect(floats.count == OmiConstants.samplesPerFrame)
        #expect(floats.allSatisfy { $0 == 0 })
    }
}

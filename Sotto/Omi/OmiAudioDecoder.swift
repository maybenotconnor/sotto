import Foundation

/// Maps the Omi codec characteristic value to a vendored codec and converts decoded
/// PCM16 bytes to the pipeline's normalized [Float]. Dropped packets and undecodable
/// frames become silence fill — never a crash, never a stalled stream. (True Opus PLC
/// is a post-hardware polish item; see spec "Error handling".)
struct OmiAudioDecoder: Sendable {
    enum DecoderError: Error, Equatable {
        case unsupportedCodec(UInt8)
    }

    let codecValue: UInt8
    private let codec: any OmiCodec

    init(codecValue: UInt8) throws {
        self.codecValue = codecValue
        switch codecValue {
        case OmiConstants.codecPCM16at16kHz:
            codec = OmiPcmCodec(sampleRate: 16_000)
        case OmiConstants.codecMuLawAt16kHz:
            codec = OmiMuLawCodec(sampleRate: 16_000)
        case OmiConstants.codecOpusAt16kHz:
            codec = try OmiOpusCodec(sampleRate: 16_000)
        default:
            // 8 kHz variants and unknown values: the pipeline is 16 kHz end-to-end;
            // resampling a legacy-firmware format is YAGNI (spec decision).
            throw DecoderError.unsupportedCodec(codecValue)
        }
    }

    func decode(_ output: OmiFrameAssembler.Output) -> [Float] {
        switch output {
        case .gap(let missingPackets):
            return silence(frames: missingPackets)
        case .frame(let data):
            guard let pcm16 = try? codec.decode(data: data) else {
                return silence(frames: 1)
            }
            guard pcm16.count % MemoryLayout<Int16>.size == 0 else {
                return silence(frames: 1)
            }
            return pcm16.withUnsafeBytes { raw in
                raw.bindMemory(to: Int16.self).map { Float(Int16(littleEndian: $0)) / 32_768.0 }
            }
        }
    }

    private func silence(frames: Int) -> [Float] {
        [Float](repeating: 0, count: frames * OmiConstants.samplesPerFrame)
    }
}

import Foundation

/// Accumulates arbitrary-length sample batches (whatever `AVAudioConverter` yields per tap
/// callback) into fixed 4096-sample `AudioChunk`s for the VAD.
///
/// `hostTime` on an emitted chunk is the host time of the `append` call that contributed
/// the chunk's first sample — sufficient for segment timestamping; not sample-exact.
struct SampleChunker {
    let chunkSize: Int
    private var pending: [Float] = []
    private var pendingHostTime: UInt64 = 0

    init(chunkSize: Int = 4096) {
        self.chunkSize = chunkSize
    }

    mutating func append(samples: [Float], hostTime: UInt64) -> [AudioChunk] {
        if pending.isEmpty {
            pendingHostTime = hostTime
        }
        pending.append(contentsOf: samples)

        var chunks: [AudioChunk] = []
        while pending.count >= chunkSize {
            chunks.append(AudioChunk(samples: Array(pending.prefix(chunkSize)), hostTime: pendingHostTime))
            pending.removeFirst(chunkSize)
            pendingHostTime = hostTime
        }
        return chunks
    }

    mutating func reset() {
        pending.removeAll()
    }
}

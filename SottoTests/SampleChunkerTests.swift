import Testing
@testable import Sotto

struct SampleChunkerTests {
    @Test func emitsNothingUntilChunkSizeReached() {
        var chunker = SampleChunker(chunkSize: 4096)
        let out = chunker.append(samples: [Float](repeating: 0.1, count: 4000), hostTime: 100)
        #expect(out.isEmpty)
    }

    @Test func emitsSingleChunkAtExactBoundary() {
        var chunker = SampleChunker(chunkSize: 4096)
        let out = chunker.append(samples: [Float](repeating: 0.1, count: 4096), hostTime: 100)
        #expect(out.count == 1)
        #expect(out[0].samples.count == 4096)
        #expect(out[0].hostTime == 100)
    }

    @Test func carriesRemainderAcrossAppendsAndStampsFirstSampleTime() {
        var chunker = SampleChunker(chunkSize: 4096)
        let first = chunker.append(samples: [Float](repeating: 0.1, count: 6000), hostTime: 100)
        #expect(first.count == 1)                       // 6000 → one chunk, 1904 pending
        let second = chunker.append(samples: [Float](repeating: 0.2, count: 2192), hostTime: 200)
        #expect(second.count == 1)                      // 1904 + 2192 = 4096
        #expect(second[0].hostTime == 100)              // chunk's first sample arrived at 100
        #expect(second[0].samples[1903] == Float(0.1))  // old samples first
        #expect(second[0].samples[1904] == Float(0.2))  // then new ones
    }

    @Test func emitsMultipleChunksFromOneLargeAppend() {
        var chunker = SampleChunker(chunkSize: 4096)
        let out = chunker.append(samples: [Float](repeating: 0.3, count: 4096 * 3), hostTime: 42)
        #expect(out.count == 3)
        #expect(out.allSatisfy { $0.samples.count == 4096 && $0.hostTime == 42 })
    }

    @Test func resetDiscardsPendingSamples() {
        var chunker = SampleChunker(chunkSize: 4096)
        _ = chunker.append(samples: [Float](repeating: 0.1, count: 4000), hostTime: 1)
        chunker.reset()
        let out = chunker.append(samples: [Float](repeating: 0.2, count: 4096), hostTime: 2)
        #expect(out.count == 1)
        #expect(out[0].samples[0] == Float(0.2))   // no stale 0.1 samples survived reset
    }
}

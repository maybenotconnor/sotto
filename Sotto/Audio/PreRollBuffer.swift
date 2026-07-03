import Foundation

/// Rolling window of the most recent audio samples (default 1 s = 16,000), continuously
/// refilled while Listening so utterance starts aren't clipped. On `.speechStart` (M2)
/// its snapshot is flushed to the segment writer ahead of live audio.
///
/// `removeFirst` is O(n) but n ≤ capacity (~16k floats) at ~4 Hz — negligible.
struct PreRollBuffer {
    let capacity: Int
    private var storage: [Float] = []

    init(capacity: Int) {
        self.capacity = capacity
    }

    mutating func append(_ samples: [Float]) {
        storage.append(contentsOf: samples)
        if storage.count > capacity {
            storage.removeFirst(storage.count - capacity)
        }
    }

    /// Buffered samples, oldest first.
    func snapshot() -> [Float] {
        storage
    }

    mutating func removeAll() {
        storage.removeAll()
    }
}

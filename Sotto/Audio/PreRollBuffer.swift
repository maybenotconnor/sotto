import Foundation

/// Rolling window of the most recent audio samples (default 1 s = 16,000), continuously
/// refilled while Listening so utterance starts aren't clipped. On `.speechStart` (M2)
/// its snapshot is flushed to the segment writer ahead of live audio.
///
/// Fixed-size circular buffer: append is O(samples appended) with no shifting. The
/// previous array-based version memmoved the full ~64 KB window on every append
/// (~4×/sec, all day, on the MainActor) — real, continuous battery cost at this
/// app's 16 h/day duty cycle.
struct PreRollBuffer {
    let capacity: Int
    private var storage: [Float]
    private var writeIndex = 0
    private var count = 0

    init(capacity: Int) {
        precondition(capacity > 0, "capacity must be positive")
        self.capacity = capacity
        self.storage = [Float](repeating: 0, count: capacity)
    }

    mutating func append(_ samples: [Float]) {
        if samples.count >= capacity {
            // Only the newest `capacity` samples can survive; lay them down in order.
            for (i, sample) in samples.suffix(capacity).enumerated() {
                storage[i] = sample
            }
            writeIndex = 0
            count = capacity
            return
        }
        for sample in samples {
            storage[writeIndex] = sample
            writeIndex = (writeIndex + 1) % capacity
        }
        count = min(count + samples.count, capacity)
    }

    /// Buffered samples, oldest first.
    func snapshot() -> [Float] {
        guard count > 0 else { return [] }
        if count < capacity {
            // Not yet wrapped: writeIndex only wraps once count reaches capacity,
            // so the valid samples occupy [0, count) in order.
            return Array(storage[..<count])
        }
        return Array(storage[writeIndex...]) + Array(storage[..<writeIndex])
    }

    mutating func removeAll() {
        writeIndex = 0
        count = 0
    }
}

import Testing
@testable import Sotto

struct PreRollBufferTests {
    @Test func retainsEverythingUnderCapacity() {
        var buffer = PreRollBuffer(capacity: 10)
        buffer.append([1, 2, 3])
        #expect(buffer.snapshot() == [1, 2, 3])
    }

    @Test func dropsOldestSamplesBeyondCapacity() {
        var buffer = PreRollBuffer(capacity: 4)
        buffer.append([1, 2, 3])
        buffer.append([4, 5, 6])
        #expect(buffer.snapshot() == [3, 4, 5, 6])
    }

    @Test func handlesSingleAppendLargerThanCapacity() {
        var buffer = PreRollBuffer(capacity: 3)
        buffer.append([1, 2, 3, 4, 5])
        #expect(buffer.snapshot() == [3, 4, 5])
    }

    @Test func removeAllEmptiesBuffer() {
        var buffer = PreRollBuffer(capacity: 4)
        buffer.append([1, 2])
        buffer.removeAll()
        #expect(buffer.snapshot().isEmpty)
    }
}

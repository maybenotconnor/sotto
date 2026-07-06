// Framing logic derived from BasedHardware/omi firmware transport.c and the omi-lib
// PacketCounter.swift sequence-validation approach (MIT, Based Hardware Contributors),
// adapted to report gap SIZE (for silence fill) instead of throwing.
import Foundation

/// Reassembles Omi BLE notifications into codec frames.
/// Wire format per notification: [uint16 LE packet#][uint8 fragment idx][payload…].
/// A frame is all notifications sharing one packet#; it is flushed when a notification
/// with a DIFFERENT packet# arrives (frames are small — one notification in practice).
struct OmiFrameAssembler: Sendable {
    enum Output: Equatable, Sendable {
        case frame(Data)
        case gap(missingPackets: Int)
    }

    private var currentPacketNumber: UInt16?
    private var currentFrame = Data()

    mutating func ingest(_ notification: Data) -> [Output] {
        guard notification.count >= OmiConstants.notificationHeaderSize else { return [] }
        let bytes = [UInt8](notification)
        let packetNumber = UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)
        let payload = notification.dropFirst(OmiConstants.notificationHeaderSize)

        guard let current = currentPacketNumber else {
            currentPacketNumber = packetNumber
            currentFrame = Data(payload)
            return []
        }

        if packetNumber == current {                      // another fragment of this frame
            currentFrame.append(payload)
            return []
        }

        var outputs: [Output] = [.frame(currentFrame)]
        let missing = Self.distance(from: current, to: packetNumber) - 1
        if missing > 0 {
            outputs.append(.gap(missingPackets: missing))
        }
        currentPacketNumber = packetNumber
        currentFrame = Data(payload)
        return outputs
    }

    mutating func reset() {
        currentPacketNumber = nil
        currentFrame = Data()
    }

    /// Forward distance on the wrapping uint16 counter (0xFFFF → 0x0000 is distance 1).
    private static func distance(from: UInt16, to: UInt16) -> Int {
        Int(to &- from)   // wrapping subtraction, reinterpreted as forward distance
    }
}

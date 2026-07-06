import Foundation
import Testing
@testable import Sotto

struct OmiFrameAssemblerTests {
    /// Builds one BLE notification: [packet# LE][fragment idx][payload].
    private func notification(_ packet: UInt16, _ index: UInt8, _ payload: [UInt8]) -> Data {
        var data = Data([UInt8(packet & 0xFF), UInt8(packet >> 8), index])
        data.append(contentsOf: payload)
        return data
    }

    @Test func singleNotificationFramesEmitWhenNextArrives() {
        var assembler = OmiFrameAssembler()
        #expect(assembler.ingest(notification(0, 0, [0xAA])) == [])       // held: may be fragmented
        #expect(assembler.ingest(notification(1, 0, [0xBB])) == [.frame(Data([0xAA]))])
        #expect(assembler.ingest(notification(2, 0, [0xCC])) == [.frame(Data([0xBB]))])
    }

    @Test func fragmentsSharingPacketNumberConcatenate() {
        var assembler = OmiFrameAssembler()
        #expect(assembler.ingest(notification(7, 0, [0x01, 0x02])) == [])
        #expect(assembler.ingest(notification(7, 1, [0x03])) == [])
        #expect(assembler.ingest(notification(8, 0, [0xFF]))
            == [.frame(Data([0x01, 0x02, 0x03]))])
    }

    @Test func wraparoundIsNotAGap() {
        var assembler = OmiFrameAssembler()
        _ = assembler.ingest(notification(0xFFFF, 0, [0x01]))
        #expect(assembler.ingest(notification(0x0000, 0, [0x02])) == [.frame(Data([0x01]))])
    }

    @Test func missedPacketsReportGapThenFrame() {
        var assembler = OmiFrameAssembler()
        _ = assembler.ingest(notification(10, 0, [0x01]))
        // 11 and 12 lost in the air; 13 arrives: flush frame 10, report 2 missing, hold 13.
        #expect(assembler.ingest(notification(13, 0, [0x02]))
            == [.frame(Data([0x01])), .gap(missingPackets: 2)])
    }

    @Test func gapAcrossWraparoundCountsCorrectly() {
        var assembler = OmiFrameAssembler()
        _ = assembler.ingest(notification(0xFFFE, 0, [0x01]))
        // Next expected 0xFFFF; receiving 1 skips 0xFFFF and 0x0000 → 2 missing.
        #expect(assembler.ingest(notification(1, 0, [0x02]))
            == [.frame(Data([0x01])), .gap(missingPackets: 2)])
    }

    @Test func malformedShortNotificationIsIgnored() {
        var assembler = OmiFrameAssembler()
        #expect(assembler.ingest(Data([0x00, 0x01])) == [])   // < 3-byte header
    }

    @Test func resetForgetsSequenceState() {
        var assembler = OmiFrameAssembler()
        _ = assembler.ingest(notification(5, 0, [0x01]))
        assembler.reset()
        // Post-reset the counter re-seeds: no gap reported, previous partial frame dropped.
        #expect(assembler.ingest(notification(90, 0, [0x02])) == [])
        #expect(assembler.ingest(notification(91, 0, [0x03])) == [.frame(Data([0x02]))])
    }
}

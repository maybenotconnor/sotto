import AVFoundation
import Foundation
import Testing
@testable import Sotto

struct HeartbeatTests {
    private func tempHeartbeat() -> HeartbeatStore {
        HeartbeatStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("hb-\(UUID().uuidString).json"))
    }

    @Test func recordReadClearRoundTrip() {
        let store = tempHeartbeat()
        #expect(store.read() == nil)
        store.record(.listening)
        #expect(store.read()?.state == "listening")
        #expect(store.indicatesUncleanShutdown)
        store.record(.idle)
        #expect(!store.indicatesUncleanShutdown)
        store.clear()
        #expect(store.read() == nil)
    }

    @Test func salvageTranscodesOrphanedCAF() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SalvageTests-\(UUID().uuidString)")
        let store = SegmentStore(rootDirectory: root)
        let paths = try store.pathsForSegment(startingAt: Date())
        do {
            let writer = try CAFSegmentWriter(cafURL: paths.cafURL, m4aURL: paths.m4aURL)
            let samples = (0..<VADConstants.sampleRate).map {
                sinf(2 * .pi * 300 * Float($0) / Float(VADConstants.sampleRate)) * 0.4
            }
            try writer.append(samples)
            // Crash: writer dropped, never finalized.
        }

        let salvaged = OrphanSalvager.salvage(store: store)

        #expect(salvaged == [paths.m4aURL])
        #expect(!FileManager.default.fileExists(atPath: paths.cafURL.path))
        let file = try AVAudioFile(forReading: paths.m4aURL)
        #expect(file.length > 0)
    }

    @Test func salvageDropsUnreadableCAF() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SalvageTests-\(UUID().uuidString)")
        let store = SegmentStore(rootDirectory: root)
        let paths = try store.pathsForSegment(startingAt: Date())
        FileManager.default.createFile(atPath: paths.cafURL.path, contents: Data([0x00, 0x01]))

        let salvaged = OrphanSalvager.salvage(store: store)

        #expect(salvaged.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: paths.cafURL.path))   // junk removed
    }
}

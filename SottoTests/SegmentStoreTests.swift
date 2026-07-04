import Foundation
import Testing
@testable import Sotto

struct SegmentStoreTests {
    private func tempStore() -> SegmentStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SegmentStoreTests-\(UUID().uuidString)")
        return SegmentStore(rootDirectory: dir)
    }

    @Test func createsLocalDateFolderAndTimeNamedPair() throws {
        let store = tempStore()
        var components = DateComponents()
        components.year = 2026; components.month = 3; components.day = 14
        components.hour = 9; components.minute = 15; components.second = 30
        let date = Calendar.current.date(from: components)!

        let paths = try store.pathsForSegment(startingAt: date)

        #expect(paths.cafURL.lastPathComponent == "09-15-30.caf")
        #expect(paths.m4aURL.lastPathComponent == "09-15-30.m4a")
        #expect(paths.cafURL.deletingLastPathComponent().lastPathComponent == "2026-03-14")
        #expect(FileManager.default.fileExists(
            atPath: paths.cafURL.deletingLastPathComponent().path))   // folder created
    }

    @Test func collidingSecondGetsSuffixedName() throws {
        let store = tempStore()
        let date = Date()
        let first = try store.pathsForSegment(startingAt: date)
        FileManager.default.createFile(atPath: first.cafURL.path, contents: Data())
        let second = try store.pathsForSegment(startingAt: date)
        #expect(second.cafURL != first.cafURL)
        #expect(second.cafURL.lastPathComponent.hasSuffix("-2.caf"))
    }

    @Test func freeDiskBytesIsPositive() {
        let store = tempStore()
        #expect(store.freeDiskBytes() > 0)
    }

    @Test func findsOrphanedCAFsRecursively() throws {
        let store = tempStore()
        let paths = try store.pathsForSegment(startingAt: Date())
        FileManager.default.createFile(atPath: paths.cafURL.path, contents: Data([0x01]))
        let orphans = store.orphanedCAFs()
        #expect(orphans == [paths.cafURL])
    }
}

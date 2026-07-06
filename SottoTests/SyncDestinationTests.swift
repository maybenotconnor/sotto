import Foundation
import Testing
@testable import Sotto

struct SyncDestinationTests {
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SyncDestinationTests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func freshSuite() -> UserDefaults {
        UserDefaults(suiteName: "sync-destination-tests-\(UUID().uuidString)")!
    }

    @Test func storeRoundTripsAFolderBookmark() throws {
        let suite = freshSuite()
        let store = SyncDestinationStore(defaults: suite)
        #expect(store.isConfigured == false)
        #expect(store.resolve() == nil)
        #expect(store.displayName == nil)

        let folder = tempDir()
        try store.save(url: folder)
        #expect(store.isConfigured == true)
        #expect(store.displayName == folder.lastPathComponent)
        #expect(store.resolve()?.standardizedFileURL.path == folder.standardizedFileURL.path)
    }

    @Test func clearRemovesTheDestination() throws {
        let suite = freshSuite()
        let store = SyncDestinationStore(defaults: suite)
        try store.save(url: tempDir())
        store.clear()
        #expect(store.isConfigured == false)
        #expect(store.resolve() == nil)
        #expect(store.displayName == nil)
    }

    @Test func resolveReturnsNilWhenTheFolderIsGone() throws {
        let suite = freshSuite()
        let store = SyncDestinationStore(defaults: suite)
        let folder = tempDir()
        try store.save(url: folder)
        try FileManager.default.removeItem(at: folder)
        #expect(store.resolve() == nil)   // deleted folder → unresolvable, not a crash
    }
}

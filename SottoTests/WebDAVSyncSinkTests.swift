import Foundation
import Testing
@testable import Sotto

struct WebDAVSyncSinkTests {
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WebDAVSink-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func freshSettings() -> SettingsStore {
        SettingsStore(defaults: UserDefaults(suiteName: "sink-webdav-\(UUID().uuidString)")!)
    }

    private func freshKeychain() -> KeychainStore {
        KeychainStore(service: "webdav-sink-test-\(UUID().uuidString)")
    }

    private func configure(_ settings: SettingsStore, keychain: KeychainStore) {
        settings.webdavServerURL = "https://dav.example.com/files/connor/Sotto"
        settings.webdavUsername = "connor"
        keychain.set("secret", for: WebDAVConfig.passwordKeychainKey)
    }

    @Test func sinkForwardsUpsertAndRemoveToTheExecutor() async throws {
        let transport = FakeWebDAVTransport(
            script: [.status(201), .status(204), .status(204)],
            fallback: .status(204))
        let executor = WebDAVExecutor(
            transport: transport, monitor: FakeNetworkMonitor(isOnWiFi: true))
        let sink = WebDAVSyncSink(
            config: makeWebDAVConfig(), wifiOnly: false, executor: executor)

        let root = tempDir()
        let dayDir = root.appendingPathComponent("2026-07-07", isDirectory: true)
        try FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)
        let m4a = dayDir.appendingPathComponent("09-15-00.m4a")
        try "t".write(to: dayDir.appendingPathComponent("09-15-00.md"),
                      atomically: true, encoding: .utf8)

        await sink.upsert(SyncSegment(m4aURL: m4a))
        await sink.remove(day: "2026-07-07", basename: "09-15-00")
        await executor.drain()

        #expect(await transport.recorded.map(\.method) == ["PUT", "DELETE", "DELETE"])
    }

    @Test func registryAppendsWebDAVSinkWhenConfiguredAndEnabled() {
        let settings = freshSettings()
        let keychain = freshKeychain()
        defer { keychain.delete(WebDAVConfig.passwordKeychainKey) }
        configure(settings, keychain: keychain)
        settings.wifiOnlyUpload = false

        let sinks = SyncSinkRegistry.activeSinks(settings, keychain: keychain)

        let webdav = sinks.compactMap { $0 as? WebDAVSyncSink }
        #expect(webdav.count == 1)
        #expect(webdav.first?.config.username == "connor")
        #expect(webdav.first?.wifiOnly == false)   // snapshots the setting per event
        // iCloud (default on) + WebDAV — both providers fan out.
        #expect(sinks.count == 2)
    }

    @Test func registryOmitsWebDAVWhenPausedOrUnconfigured() {
        let keychain = freshKeychain()
        defer { keychain.delete(WebDAVConfig.passwordKeychainKey) }

        let paused = freshSettings()
        configure(paused, keychain: keychain)
        paused.webdavEnabled = false
        #expect(SyncSinkRegistry.activeSinks(paused, keychain: keychain)
            .compactMap { $0 as? WebDAVSyncSink }.isEmpty)

        let unconfigured = freshSettings()   // nothing saved at all
        #expect(SyncSinkRegistry.activeSinks(unconfigured, keychain: freshKeychain())
            .compactMap { $0 as? WebDAVSyncSink }.isEmpty)
    }
}

import Foundation
import Testing
@testable import Sotto

struct WebDAVExecutorTests {
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WebDAVExecutor-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// `<root>/<day>/<name>.md [+ .m4a]`; returns the SyncSegment (same shape the fan-out builds).
    private func makeSegment(
        root: URL, day: String = "2026-07-07", name: String = "09-15-00", m4a: Bool = true
    ) throws -> SyncSegment {
        let dayDir = root.appendingPathComponent(day, isDirectory: true)
        try FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)
        let m4aURL = dayDir.appendingPathComponent("\(name).m4a")
        if m4a { try Data([0x01]).write(to: m4aURL) }
        try "transcript".write(
            to: dayDir.appendingPathComponent("\(name).md"), atomically: true, encoding: .utf8)
        return SyncSegment(m4aURL: m4aURL)
    }

    private func makeExecutor(
        _ transport: FakeWebDAVTransport, wifi: Bool = true
    ) -> WebDAVExecutor {
        WebDAVExecutor(transport: transport, monitor: FakeNetworkMonitor(isOnWiFi: wifi))
    }

    @Test func upsertPutsMarkdownOnlyWhenAudioDisabled() async throws {
        let transport = FakeWebDAVTransport()
        let executor = makeExecutor(transport)
        let segment = try makeSegment(root: tempDir())

        await executor.upsert(segment, config: makeWebDAVConfig(), wifiOnly: false)
        await executor.drain()

        let recorded = await transport.recorded
        #expect(recorded.map(\.method) == ["PUT"])
        #expect(recorded[0].url.absoluteString
            == "https://dav.example.com/files/connor/Sotto/2026-07-07/09-15-00.md")
        if case .ok = await executor.lastOutcome {} else {
            Issue.record("expected .ok, got \(await executor.lastOutcome)")
        }
    }

    @Test func upsertAlsoPutsAudioWhenEnabled() async throws {
        let transport = FakeWebDAVTransport()
        let executor = makeExecutor(transport)
        let segment = try makeSegment(root: tempDir())

        await executor.upsert(segment, config: makeWebDAVConfig(audio: true), wifiOnly: false)
        await executor.drain()

        let urls = await transport.recorded.map(\.url.lastPathComponent)
        #expect(urls == ["09-15-00.md", "09-15-00.m4a"])
    }

    @Test func upsertSelfHealsMissingDayVia409MkcolRetry() async throws {
        let transport = FakeWebDAVTransport(
            script: [.status(409), .status(201), .status(201)])
        let executor = makeExecutor(transport)
        let segment = try makeSegment(root: tempDir())

        await executor.upsert(segment, config: makeWebDAVConfig(), wifiOnly: false)
        await executor.drain()

        let recorded = await transport.recorded
        #expect(recorded.map(\.method) == ["PUT", "MKCOL", "PUT"])
        #expect(recorded[1].url.absoluteString
            == "https://dav.example.com/files/connor/Sotto/2026-07-07/")
        if case .ok = await executor.lastOutcome {} else {
            Issue.record("self-healed op should record .ok")
        }
    }

    @Test func removeDeletesBothExtensionsTolerating404() async throws {
        let transport = FakeWebDAVTransport(fallback: .status(404))
        let executor = makeExecutor(transport)

        await executor.remove(day: "2026-07-07", basename: "09-15-00",
                        config: makeWebDAVConfig(), wifiOnly: false)
        await executor.drain()

        let recorded = await transport.recorded
        #expect(recorded.map(\.method) == ["DELETE", "DELETE"])
        #expect(recorded.map(\.url.lastPathComponent) == ["09-15-00.md", "09-15-00.m4a"])
        if case .ok = await executor.lastOutcome {} else {
            Issue.record("404s are tolerated — outcome must be .ok")
        }
    }

    @Test func opsExecuteStrictlyFIFO() async throws {
        // 204 (not the default 201 fallback) so the fake's blanket response is accepted by
        // BOTH the PUT (accepts 200/201/204) and the two DELETEs (accept 200/204/404) this
        // test issues — 201 alone would make the first DELETE throw and never reach the second.
        let transport = FakeWebDAVTransport(fallback: .status(204))
        let executor = makeExecutor(transport)
        let segment = try makeSegment(root: tempDir())
        let config = makeWebDAVConfig()

        // The resurrection race: upsert then immediate remove of the SAME path. FIFO must
        // hold the DELETE until the PUT completed.
        await executor.upsert(segment, config: config, wifiOnly: false)
        await executor.remove(day: segment.day, basename: segment.basename,
                        config: config, wifiOnly: false)
        await executor.drain()

        #expect(await transport.recorded.map(\.method) == ["PUT", "DELETE", "DELETE"])
    }

    @Test func wifiGateSkipsEventOpsAndRecordsIt() async throws {
        let transport = FakeWebDAVTransport()
        let executor = makeExecutor(transport, wifi: false)
        let segment = try makeSegment(root: tempDir())

        await executor.upsert(segment, config: makeWebDAVConfig(), wifiOnly: true)
        await executor.drain()

        #expect(await transport.recorded.isEmpty)
        if case .skippedWiFi = await executor.lastOutcome {} else {
            Issue.record("expected .skippedWiFi")
        }
    }

    @Test func unauthorizedRecordsAuthenticationFailure() async throws {
        let transport = FakeWebDAVTransport(fallback: .status(401))
        let executor = makeExecutor(transport)
        let segment = try makeSegment(root: tempDir())

        await executor.upsert(segment, config: makeWebDAVConfig(), wifiOnly: false)
        await executor.drain()

        if case .failed(let reason, _) = await executor.lastOutcome {
            #expect(reason == "authentication failed")
        } else {
            Issue.record("expected .failed")
        }
    }

    @Test func testConnectionMapsTheFourOutcomes() async throws {
        let cases: [(FakeWebDAVTransport.Scripted, WebDAVTestResult)] = [
            (.status(207), .connected),
            (.status(401), .unauthorized),
            (.status(404), .notFound),
            (.error(URLError(.cannotConnectToHost)), .failed("server unreachable")),
        ]
        for (scripted, expected) in cases {
            let executor = makeExecutor(FakeWebDAVTransport(fallback: scripted))
            #expect(await executor.testConnection(config: makeWebDAVConfig()) == expected)
        }
    }
}

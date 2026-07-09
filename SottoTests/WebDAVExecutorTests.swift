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

    // MARK: Sweep + restore (Task 6)

    @Test func backupAllSweepsTranscriptsAndSkipsInternalFiles() async throws {
        let transport = FakeWebDAVTransport()
        // Wi-Fi off + wifiOnlyUpload is irrelevant: manual ops bypass the gate.
        let executor = makeExecutor(transport, wifi: false)
        let root = tempDir()
        _ = try makeSegment(root: root, day: "2026-07-05", name: "09-15-00")
        _ = try makeSegment(root: root, day: "2026-07-06", name: "11-00-00")
        let day = root.appendingPathComponent("2026-07-05", isDirectory: true)
        try Data().write(to: day.appendingPathComponent("_day.json"))
        try Data().write(to: day.appendingPathComponent("stray.caf"))

        let counts = await executor.backupAll(localRoot: root, config: makeWebDAVConfig())

        #expect(counts.transcripts == 2)
        #expect(counts.audio == 0)
        let names = Set(await transport.recorded.map(\.url.lastPathComponent))
        #expect(names == ["09-15-00.md", "11-00-00.md"])   // no _day.json, no .caf, no .m4a
    }

    @Test func backupAllIncludesAudioWhenEnabled() async throws {
        let transport = FakeWebDAVTransport()
        let executor = makeExecutor(transport)
        let root = tempDir()
        _ = try makeSegment(root: root, day: "2026-07-05", name: "09-15-00")

        let counts = await executor.backupAll(
            localRoot: root, config: makeWebDAVConfig(audio: true))

        #expect(counts.transcripts == 1)
        #expect(counts.audio == 1)
        let names = Set(await transport.recorded.map(\.url.lastPathComponent))
        #expect(names == ["09-15-00.md", "09-15-00.m4a"])
    }

    /// Multistatus for the base: the base itself, one day collection, one foreign file.
    private func baseListing() -> Data {
        Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <d:multistatus xmlns:d="DAV:">
          <d:response><d:href>/files/connor/Sotto/</d:href>
            <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop></d:propstat>
          </d:response>
          <d:response><d:href>/files/connor/Sotto/2026-07-05/</d:href>
            <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop></d:propstat>
          </d:response>
          <d:response><d:href>/files/connor/Sotto/passwords.txt</d:href>
            <d:propstat><d:prop><d:resourcetype/></d:prop></d:propstat>
          </d:response>
        </d:multistatus>
        """.utf8)
    }

    /// Multistatus for the day: two shaped transcripts + one foreign file.
    private func dayListing() -> Data {
        Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <d:multistatus xmlns:d="DAV:">
          <d:response><d:href>/files/connor/Sotto/2026-07-05/</d:href>
            <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop></d:propstat>
          </d:response>
          <d:response><d:href>/files/connor/Sotto/2026-07-05/09-15-00.md</d:href>
            <d:propstat><d:prop><d:resourcetype/></d:prop></d:propstat>
          </d:response>
          <d:response><d:href>/files/connor/Sotto/2026-07-05/10-30-00.md</d:href>
            <d:propstat><d:prop><d:resourcetype/></d:prop></d:propstat>
          </d:response>
          <d:response><d:href>/files/connor/Sotto/2026-07-05/readme.txt</d:href>
            <d:propstat><d:prop><d:resourcetype/></d:prop></d:propstat>
          </d:response>
        </d:multistatus>
        """.utf8)
    }

    /// Minimal valid transcript (frontmatter parseable by DayIndexRebuilder).
    private func transcriptBody(iso: String) -> String {
        """
        ---
        date: \(iso)
        duration: 12.0
        backend: speechAnalyzer
        title: Restored chat
        ---

        **Speaker 0:** hello there
        """
    }

    @Test func restoreFetchesOnlyMissingShapedFilesAndRebuildsIndex() async throws {
        let root = tempDir()
        // 10-30-00 already exists locally — restore must not overwrite or re-fetch it.
        let localDay = root.appendingPathComponent("2026-07-05", isDirectory: true)
        try FileManager.default.createDirectory(at: localDay, withIntermediateDirectories: true)
        try "LOCAL WINS".write(to: localDay.appendingPathComponent("10-30-00.md"),
                               atomically: true, encoding: .utf8)

        let transport = FakeWebDAVTransport(script: [
            .status(207, baseListing()),   // PROPFIND base, depth 1
            .status(207, dayListing()),    // PROPFIND 2026-07-05, depth 1
            .status(200, Data(transcriptBody(iso: "2026-07-05T09:15:00Z").utf8)),  // GET 09-15-00.md
        ])
        let executor = makeExecutor(transport)
        let dayIndex = DayIndexStore(rootDirectory: root)

        let restored = await executor.restore(
            localRoot: root, config: makeWebDAVConfig(), dayIndex: dayIndex)

        #expect(restored == 1)
        let methods = await transport.recorded.map(\.method)
        #expect(methods == ["PROPFIND", "PROPFIND", "GET"])   // exactly one GET — the missing file
        #expect(try String(contentsOf: localDay.appendingPathComponent("10-30-00.md"),
                           encoding: .utf8) == "LOCAL WINS")
        let index = await dayIndex.index(forDay: localDay)
        #expect(index?.segments.contains { $0.hasAudio == false } == true)
    }

    @Test func restoreSecondRunIsANoOp() async throws {
        let root = tempDir()
        let script: [FakeWebDAVTransport.Scripted] = [
            .status(207, baseListing()),
            .status(207, dayListing()),
            .status(200, Data(transcriptBody(iso: "2026-07-05T09:15:00Z").utf8)),
            .status(200, Data(transcriptBody(iso: "2026-07-05T10:30:00Z").utf8)),
        ]
        let transport = FakeWebDAVTransport(script: script)
        let executor = makeExecutor(transport)
        let dayIndex = DayIndexStore(rootDirectory: root)

        let first = await executor.restore(
            localRoot: root, config: makeWebDAVConfig(), dayIndex: dayIndex)
        #expect(first == 2)

        // Fresh transport/script; same local state — everything already present.
        let transport2 = FakeWebDAVTransport(script: [
            .status(207, baseListing()), .status(207, dayListing()),
        ])
        let executor2 = WebDAVExecutor(
            transport: transport2, monitor: FakeNetworkMonitor(isOnWiFi: true))
        let second = await executor2.restore(
            localRoot: root, config: makeWebDAVConfig(), dayIndex: dayIndex)

        #expect(second == 0)
        #expect(await transport2.recorded.map(\.method) == ["PROPFIND", "PROPFIND"])   // no GETs
    }

    @Test func restoreSurvivesAnUnreachableServer() async throws {
        let transport = FakeWebDAVTransport(fallback: .error(URLError(.cannotConnectToHost)))
        let executor = makeExecutor(transport)
        let root = tempDir()
        let restored = await executor.restore(
            localRoot: root, config: makeWebDAVConfig(), dayIndex: DayIndexStore(rootDirectory: root))
        #expect(restored == 0)
    }
}

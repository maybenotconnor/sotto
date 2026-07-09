import Foundation

/// Settings status line: the executor's most recent outcome. In-memory, resets per launch
/// — a diagnostic, not a ledger. A success clears a failure.
enum WebDAVStatus: Sendable {
    case idle
    case ok(Date)
    case skippedWiFi(Date)
    case failed(String, Date)
}

/// Settings "Test connection" result — the view maps these to copy (design §5).
enum WebDAVTestResult: Equatable, Sendable {
    case connected
    case unauthorized
    case notFound
    case failed(String)
}

/// The single long-lived WebDAV pipeline (design §3). Strict FIFO — one operation
/// completes before the next starts — which is the entire fix for the PUT-vs-DELETE
/// resurrection race: sinks stay fresh-per-event (instant settings application), and this
/// actor is the state that must span events. Event-driven ops honor the Wi-Fi gate at
/// execution time; manual sweep/restore/test bypass it (explicit user intent) but still
/// serialize behind pending ops. Best-effort throughout: failures record `lastOutcome`
/// and drop the op — the "Back up now" sweep is the recovery path.
actor WebDAVExecutor {
    static let shared = WebDAVExecutor()

    // Immutable + Sendable, so the chained op tasks read them without actor hops
    // (nonisolated access to actor `let`s).
    private let transport: any WebDAVTransport
    private let monitor: any NetworkMonitoring

    private var tail: Task<Void, Never>?
    private(set) var lastOutcome: WebDAVStatus = .idle

    init(transport: any WebDAVTransport = URLSession.shared,
         monitor: any NetworkMonitoring = WiFiMonitor()) {
        self.transport = transport
        self.monitor = monitor
    }

    // MARK: Event-driven ops (fire-and-forget, Wi-Fi gated)

    /// Mirror a finalized conversation: PUT the .md, plus the .m4a when the config says so.
    func upsert(_ segment: SyncSegment, config: WebDAVConfig, wifiOnly: Bool) {
        schedule { [monitor = self.monitor, transport = self.transport] in
            if wifiOnly, !monitor.isOnWiFi { return .skippedWiFi }
            let client = WebDAVClient(config: config, transport: transport)
            do {
                try await Self.putCreatingDay(
                    client, base: config.baseURL, day: segment.day,
                    file: segment.markdown, contentType: "text/markdown")
                if config.audioEnabled, let audio = segment.audio {
                    try await Self.putCreatingDay(
                        client, base: config.baseURL, day: segment.day,
                        file: audio, contentType: "audio/mp4")
                }
                return .ok
            } catch {
                return .failure(error)
            }
        }
    }

    /// Propagate a deletion: both extensions, 404s tolerated by the client — `remove`
    /// carries no knowledge of whether audio was ever mirrored (design §4).
    func remove(day: String, basename: String, config: WebDAVConfig, wifiOnly: Bool) {
        schedule { [monitor = self.monitor, transport = self.transport] in
            if wifiOnly, !monitor.isOnWiFi { return .skippedWiFi }
            let client = WebDAVClient(config: config, transport: transport)
            let dayURL = config.baseURL.appendingPathComponent(day, isDirectory: true)
            do {
                try await client.delete(dayURL.appendingPathComponent("\(basename).md"))
                try await client.delete(dayURL.appendingPathComponent("\(basename).m4a"))
                return .ok
            } catch {
                return .failure(error)
            }
        }
    }

    // MARK: Manual ops (awaited, serialized, no Wi-Fi gate)

    /// Settings "Test connection": PROPFIND Depth 0 on the base. Doesn't touch
    /// `lastOutcome` — its result is reported inline in the form, not the status line.
    func testConnection(config: WebDAVConfig) async -> WebDAVTestResult {
        let transport = self.transport
        return await runSerialized {
            do {
                _ = try await WebDAVClient(config: config, transport: transport)
                    .propfind(config.baseURL, depth: 0)
                return .connected
            } catch WebDAVError.unauthorized {
                return .unauthorized
            } catch WebDAVError.notFound {
                return .notFound
            } catch {
                return .failed(Self.describe(error))
            }
        }
    }

    /// Settings "Back up now" (design §6): first-configure backfill, audio-toggle backfill,
    /// and the universal recovery path. Walks `<localRoot>/<day>/` two levels (the store
    /// layout is exactly two levels; skips `_day.json`/`.caf` by extension), PUTs every
    /// .md — and .m4a when the config says so. Per-file failures skip and continue; the
    /// first failure decides the recorded status.
    func backupAll(localRoot: URL, config: WebDAVConfig) async -> (transcripts: Int, audio: Int) {
        let transport = self.transport
        return await runSerialized {
            let client = WebDAVClient(config: config, transport: transport)
            var transcripts = 0, audio = 0
            var firstFailure: (any Error)?
            let days = (try? FileManager.default.contentsOfDirectory(
                at: localRoot, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            for day in days {
                guard (try? day.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                      let files = try? FileManager.default.contentsOfDirectory(
                          at: day, includingPropertiesForKeys: nil) else { continue }
                for file in files {
                    let contentType: String? = switch file.pathExtension {
                    case "md": "text/markdown"
                    case "m4a" where config.audioEnabled: "audio/mp4"
                    default: nil   // _day.json, .caf, audio when disabled
                    }
                    guard let contentType else { continue }
                    do {
                        try await Self.putCreatingDay(
                            client, base: config.baseURL, day: day.lastPathComponent,
                            file: file, contentType: contentType)
                        if contentType == "text/markdown" { transcripts += 1 } else { audio += 1 }
                    } catch {
                        if firstFailure == nil { firstFailure = error }
                    }
                }
            }
            await self.record(firstFailure.map { .failure($0) } ?? .ok)
            return (transcripts, audio)
        }
    }

    /// Settings "Restore from server" (design §6): additive, idempotent, transcripts only.
    /// Depth-1 PROPFIND walk (never infinity — servers commonly disable it); only
    /// Sotto-shaped paths (`yyyy-MM-dd/HH-mm-ss.md`) are considered — foreign files are
    /// invisible, which is what makes "exact URL, no subfolder" safe. Never overwrites a
    /// local file; rebuilds `_day.json` per touched day (restored conversations get
    /// hasAudio = false from the rebuilder — audio is not restored, same asymmetry as
    /// iCloud). Doesn't touch `lastOutcome`: its result is reported inline. Returns nil
    /// when the base listing itself fails (server unreachable/unauthorized/not found) —
    /// distinct from 0, which means the server was reached and had nothing to restore.
    /// Per-day listing/GET failures still skip-and-continue: a partial restore is a count.
    func restore(localRoot: URL, config: WebDAVConfig, dayIndex: DayIndexStore) async -> Int? {
        let transport = self.transport
        return await runSerialized {
            let client = WebDAVClient(config: config, transport: transport)
            guard let baseData = try? await client.propfind(config.baseURL, depth: 1)
            else { return nil }

            let basePath = Self.normalizedPath(config.baseURL.path)
            let days = WebDAVMultistatus.parse(baseData).filter { entry in
                entry.isCollection
                    && Self.normalizedPath(entry.href) != basePath   // skip the base itself
                    && Self.lastComponent(entry.href)
                        .wholeMatch(of: /\d{4}-\d{2}-\d{2}/) != nil
            }

            var restored = 0
            var touchedDays: Set<String> = []
            for dayEntry in days {
                let day = Self.lastComponent(dayEntry.href)
                let dayURL = config.baseURL.appendingPathComponent(day, isDirectory: true)
                guard let listing = try? await client.propfind(dayURL, depth: 1)
                else { continue }
                let files = WebDAVMultistatus.parse(listing).filter { entry in
                    !entry.isCollection
                        && Self.lastComponent(entry.href)
                            .wholeMatch(of: /\d{2}-\d{2}-\d{2}\.md/) != nil
                }
                for file in files {
                    let name = Self.lastComponent(file.href)
                    let localDay = localRoot.appendingPathComponent(day, isDirectory: true)
                    let localMD = localDay.appendingPathComponent(name)
                    guard !FileManager.default.fileExists(atPath: localMD.path)
                    else { continue }   // never overwrite — local is canonical
                    guard let data = try? await client.get(
                        dayURL.appendingPathComponent(name)) else { continue }
                    try? FileManager.default.createDirectory(
                        at: localDay, withIntermediateDirectories: true)
                    guard (try? data.write(to: localMD)) != nil else { continue }
                    restored += 1
                    touchedDays.insert(day)
                }
            }

            for day in touchedDays {
                _ = await dayIndex.rebuildAndPersist(
                    dayDirectory: localRoot.appendingPathComponent(day, isDirectory: true))
            }
            return restored
        }
    }

    /// "/a/b/" and "/a/b" are the same collection.
    private static func normalizedPath(_ path: String) -> String {
        path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    private static func lastComponent(_ href: String) -> String {
        href.split(separator: "/").last.map(String.init) ?? ""
    }

    /// Test synchronization only: awaits everything enqueued so far.
    func drain() async {
        await tail?.value
    }

    // MARK: FIFO machinery

    private enum OpOutcome {
        case ok
        case skippedWiFi
        case failure(any Error)
    }

    /// Fire-and-forget FIFO enqueue: the sink returns immediately; the op runs after every
    /// previously enqueued op, then records its outcome. Enqueue order is actor-arrival
    /// order — event ops arrive seconds apart in practice, and the only same-instant
    /// multi-op event (merge) targets different paths, so relative order there is moot.
    private func schedule(_ work: @escaping @Sendable () async -> OpOutcome) {
        let previous = tail
        tail = Task { [previous] in
            await previous?.value
            let outcome = await work()
            // No hop needed: this Task inherits the actor isolation of `schedule`'s caller.
            self.record(outcome)
        }
    }

    /// Serialized-and-awaited, for manual ops: runs behind everything already queued and
    /// hands the result back. Task 6 builds sweep/restore on this.
    func runSerialized<T: Sendable>(_ work: @escaping @Sendable () async -> T) async -> T {
        let previous = tail
        let task = Task { [previous] in
            await previous?.value
            return await work()
        }
        tail = Task { _ = await task.value }
        return await task.value
    }

    private func record(_ outcome: OpOutcome) {
        switch outcome {
        case .ok: lastOutcome = .ok(Date())
        case .skippedWiFi: lastOutcome = .skippedWiFi(Date())
        case .failure(let error): lastOutcome = .failed(Self.describe(error), Date())
        }
    }

    // MARK: Shared helpers (Task 6's sweep reuses both)

    /// PUT with the missing-day self-heal (design §4): try direct; on "parent collection
    /// missing" (RFC 4918 says 409; some servers answer 404) MKCOL the day and retry once.
    /// No proactive MKCOL and no created-days cache — this path heals every time, including
    /// when the server folder is deleted externally mid-run.
    static func putCreatingDay(
        _ client: WebDAVClient, base: URL, day: String, file: URL, contentType: String
    ) async throws {
        let dayURL = base.appendingPathComponent(day, isDirectory: true)
        let target = dayURL.appendingPathComponent(file.lastPathComponent)
        do {
            try await client.putFile(file, to: target, contentType: contentType)
        } catch WebDAVError.conflict, WebDAVError.notFound {
            try await client.mkcol(dayURL)
            try await client.putFile(file, to: target, contentType: contentType)
        }
    }

    /// Status-line copy for the §4 error taxonomy.
    static func describe(_ error: any Error) -> String {
        switch error {
        case WebDAVError.unauthorized: "authentication failed"
        case WebDAVError.notFound: "folder not found"
        case WebDAVError.conflict: "folder could not be created"
        case WebDAVError.insufficientStorage: "server is full"
        case WebDAVError.server(let code): "server error (\(code))"
        case is URLError: "server unreachable"
        default: "network error"
        }
    }
}

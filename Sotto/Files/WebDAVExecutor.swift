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

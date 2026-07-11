import Foundation
import Network
import Synchronization

/// Network-reachability seam: `WiFiGatedService` below consults this to decide whether a
/// Deepgram upload may proceed under Settings' "Wi-Fi only" toggle (SPEC "Transcription
/// layer"). A protocol (not a concrete type) so tests substitute a fixed answer instead of
/// depending on the device's actual network state.
protocol NetworkMonitoring: Sendable {
    var isOnWiFi: Bool { get }
}

/// Holds the monitor's latest `NWPath` behind a `Mutex` — `NWPathMonitor`'s callback fires on
/// its own background queue, never synchronized with callers of `isOnWiFi`. A `final class`
/// (not a stored property directly on `WiFiMonitor`) because `Mutex` is non-copyable, and
/// `WiFiMonitor` needs to stay a trivially-`Sendable`, `Copyable` `struct` per the seam's
/// contract.
private final class WiFiPathBox: Sendable {
    private let stored = Mutex<NWPath?>(nil)

    func update(_ path: NWPath) {
        stored.withLock { $0 = path }
    }

    var current: NWPath? {
        stored.withLock { $0 }
    }
}

/// Real implementation: starts an `NWPathMonitor` at construction (its callback fires
/// asynchronously as soon as the system has an answer) rather than on first read, so
/// `isOnWiFi` is never blocked waiting on the initial path.
struct WiFiMonitor: NetworkMonitoring {
    private let box = WiFiPathBox()
    private let monitor: NWPathMonitor

    init() {
        let monitor = NWPathMonitor()
        let box = self.box
        monitor.pathUpdateHandler = { path in box.update(path) }
        monitor.start(queue: DispatchQueue(label: "app.decanlys.sotto.WiFiMonitor", qos: .utility))
        self.monitor = monitor
    }

    /// Fail-open: before the monitor's first callback (or if the interface type is ever
    /// indeterminate), treat the network as available rather than silently and permanently
    /// blocking uploads — "Wi-Fi only" is a courtesy toggle, not a hard guarantee, and the
    /// alternative (fail-closed) would strand jobs pending forever on a monitor glitch.
    var isOnWiFi: Bool {
        box.current?.usesInterfaceType(.wifi) ?? true
    }
}

/// Wraps a `TranscriptionService` so a job attempted off Wi-Fi (with the "Wi-Fi only" toggle
/// on) fails the SAME way as "assets not installed"/offline — `.unavailable` — reusing the
/// existing environmental classification in `TranscriptionQueue.isEnvironmental` rather than
/// introducing a new one: the job stays `.pending` with no attempts burned, and the drain
/// stops there rather than probing later jobs pointlessly.
struct WiFiGatedService: TranscriptionService {
    let inner: any TranscriptionService
    let allowed: @Sendable () -> Bool

    var backend: TranscriptionBackend { inner.backend }

    func transcribe(file: URL) async throws -> TranscriptionResult {
        guard allowed() else { throw TranscriptionError.unavailable }
        return try await inner.transcribe(file: file)
    }
}

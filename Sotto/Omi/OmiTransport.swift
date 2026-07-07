import Foundation

/// Reasons Core Bluetooth reports the radio itself as unusable — distinct from a
/// per-device connection failure (see `OmiConnectionState.unavailable`).
enum OmiBluetoothUnavailableReason: String, Sendable, Equatable {
    case poweredOff
    case unauthorized
    case unsupported
}

/// Lifecycle events surfaced by the transport while `events(deviceID:)` is active.
enum OmiTransportEvent: Sendable, Equatable {
    case connecting
    case connected(codecValue: UInt8)
    case audioNotification(Data)
    case batteryLevel(Int)                 // percent 0–100
    case disconnected
    case bluetoothUnavailable(OmiBluetoothUnavailableReason)
}

/// A discovered-but-not-yet-paired Omi peripheral.
struct OmiDiscovery: Sendable, Equatable, Identifiable {
    let id: UUID
    let name: String
    let rssi: Int
}

/// The hardware quarantine seam: everything Core Bluetooth-shaped lives behind this
/// protocol so `OmiAudioSource` (and its tests) never touch CoreBluetooth directly.
protocol OmiTransport: Sendable {
    func scan() async -> AsyncStream<OmiDiscovery>
    func stopScan() async
    /// Connect to the peripheral and MAINTAIN the connection (immediate pending
    /// re-connect on disconnect) until stopEvents(). Repeatable after stopEvents().
    func events(deviceID: UUID) async -> AsyncStream<OmiTransportEvent>
    /// MUST finish the stream returned by `events(deviceID:)` on every path (including
    /// when called while a connect is pending) — `OmiAudioSource.stop()` awaits its event
    /// pump to completion and would hang forever on a transport that never finishes it.
    func stopEvents() async
}

/// The connection lifecycle relayed to observers (AppModel, FailoverAudioSource, Settings).
enum OmiConnectionState: Sendable, Equatable {
    case disconnected
    case connecting
    case connected
    case streaming
    case unavailable(OmiBluetoothUnavailableReason)
}

/// An `AudioSource` that also exposes its connection lifecycle as a multicast stream.
protocol ConnectableAudioSource: AudioSource {
    /// New independent stream per call (multicast) — FailoverAudioSource and AppModel
    /// both observe.
    func connectionStates() async -> AsyncStream<OmiConnectionState>
}

import Foundation

/// Lifecycle events surfaced by the transport while `events(deviceID:)` is active.
enum OmiTransportEvent: Sendable, Equatable {
    case connecting
    case connected(codecValue: UInt8)
    case audioNotification(Data)
    case batteryLevel(Int)                 // percent 0–100
    case disconnected
    case bluetoothUnavailable(BluetoothUnavailableReason)
}

/// The hardware quarantine seam: everything Core Bluetooth-shaped lives behind this
/// protocol so `OmiAudioSource` (and its tests) never touch CoreBluetooth directly.
/// Device-internal on purpose — the generic seam is `WearableAudioSource` (and
/// `DeviceScanning` for pairing); handshakes don't share a shape across vendors, so
/// each device family brings its own transport protocol.
protocol OmiTransport: DeviceScanning {
    /// Connect to the peripheral and MAINTAIN the connection (immediate pending
    /// re-connect on disconnect) until stopEvents(). Repeatable after stopEvents().
    func events(deviceID: UUID) async -> AsyncStream<OmiTransportEvent>
    /// MUST finish the stream returned by `events(deviceID:)` on every path (including
    /// when called while a connect is pending) — `OmiAudioSource.stop()` awaits its event
    /// pump to completion and would hang forever on a transport that never finishes it.
    func stopEvents() async
}

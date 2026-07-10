import Foundation

/// Catalog of pairable wearable families. All user-facing device copy renders from
/// this — generic code never hardcodes a device family name.
enum DeviceKind: String, Codable, Sendable, CaseIterable {
    case omi

    /// The pipeline/persistence label this family's chunks are tagged with.
    var sourceType: AudioSourceType {
        switch self {
        case .omi: .omi
        }
    }

    /// User-facing family name — delegates to the source-type label so the home
    /// header, Live Activity, Settings, and notifications all agree.
    var displayName: String { sourceType.displayName }
}

/// Reasons Core Bluetooth reports the radio itself as unusable — distinct from a
/// per-device connection failure (see `DeviceConnectionState.unavailable`).
enum BluetoothUnavailableReason: String, Sendable, Equatable {
    case poweredOff
    case unauthorized
    case unsupported
}

/// The connection lifecycle relayed to observers (AppModel, FailoverAudioSource,
/// Settings).
enum DeviceConnectionState: Sendable, Equatable {
    case disconnected
    case connecting
    case connected
    case streaming
    case unavailable(BluetoothUnavailableReason)
}

/// A discovered-but-not-yet-paired wearable peripheral. `kind` is stamped by the
/// transport doing the scanning (each transport scans exactly one family).
struct WearableDiscovery: Sendable, Equatable, Identifiable {
    let id: UUID
    let name: String
    let rssi: Int
    let kind: DeviceKind
}

/// Discovery-only slice of a device transport. `PairDeviceSheet` and
/// `AppModel.makeScanTransport(for:)` depend on this, never on a device module's
/// transport protocol — generic code must not name device-module types.
protocol DeviceScanning: Sendable {
    func scan() async -> AsyncStream<WearableDiscovery>
    func stopScan() async
}

/// An `AudioSource` that also exposes its connection lifecycle as a multicast stream.
protocol ConnectableAudioSource: AudioSource {
    /// New independent stream per call (multicast) — FailoverAudioSource and AppModel
    /// both observe.
    func connectionStates() async -> AsyncStream<DeviceConnectionState>
}

/// The full wearable seam: what AppModel's Settings observation needs beyond
/// failover's needs. One implementation per device family — the device module owns
/// its transport, framing, and decode; this is the portable boundary (decoded 16 kHz
/// chunks + lifecycle + battery).
protocol WearableAudioSource: ConnectableAudioSource {
    func batteryLevels() async -> AsyncStream<Int>
    var latestBatteryLevel: Int? { get async }
    var setupFailureMessage: String? { get async }
}

enum WearableConstants {
    static let lowBatteryThresholdPercent = 15
}

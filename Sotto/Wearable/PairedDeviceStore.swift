import Foundation

/// Persists the single paired wearable (spec: auto-prefer one device; pair/forget
/// only). The UserDefaults key predates the multi-device generalization and is kept
/// verbatim so existing pairings survive.
final class PairedDeviceStore: Sendable {
    private static let key = "pairedOmiDevice"
    // UserDefaults isn't marked Sendable on this SDK, but it is documented as internally
    // thread-safe (all instance methods may be called from any thread) — nonisolated(unsafe)
    // is safe here, matching `SettingsStore.defaults`.
    private nonisolated(unsafe) let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var device: PairedDevice? {
        guard let data = defaults.data(forKey: Self.key) else { return nil }
        return try? JSONDecoder().decode(PairedDevice.self, from: data)
    }

    func pair(_ device: PairedDevice) {
        defaults.set(try? JSONEncoder().encode(device), forKey: Self.key)
    }

    func forget() {
        defaults.removeObject(forKey: Self.key)
    }
}

struct PairedDevice: Codable, Equatable, Sendable {
    let id: UUID
    let name: String
    let kind: DeviceKind

    init(id: UUID, name: String, kind: DeviceKind) {
        self.id = id
        self.name = name
        self.kind = kind
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        // Legacy records (pre-generalization `PairedOmiDevice`) carry no kind field —
        // they are Omi pairings by construction.
        kind = try container.decodeIfPresent(DeviceKind.self, forKey: .kind) ?? .omi
    }
}

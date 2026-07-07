import Foundation

/// Persists the single paired Omi (spec: auto-prefer one device; pair/forget only).
final class OmiDeviceStore: Sendable {
    private static let key = "pairedOmiDevice"
    // UserDefaults isn't marked Sendable on this SDK, but it is documented as internally
    // thread-safe (all instance methods may be called from any thread) — nonisolated(unsafe)
    // is safe here, matching `SettingsStore.defaults`.
    private nonisolated(unsafe) let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var device: PairedOmiDevice? {
        guard let data = defaults.data(forKey: Self.key) else { return nil }
        return try? JSONDecoder().decode(PairedOmiDevice.self, from: data)
    }

    func pair(_ device: PairedOmiDevice) {
        defaults.set(try? JSONEncoder().encode(device), forKey: Self.key)
    }

    func forget() {
        defaults.removeObject(forKey: Self.key)
    }
}

struct PairedOmiDevice: Codable, Equatable, Sendable {
    let id: UUID
    let name: String
}

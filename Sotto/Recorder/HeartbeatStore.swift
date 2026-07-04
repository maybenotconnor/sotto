import Foundation

/// Tiny state file persisted on every recorder transition (SPEC "Unclean shutdown
/// detection"): on launch, heartbeat says "listening" but we're cold-starting → the app
/// died. M5 records the gap in `_day.json`; M2 salvages the audio and surfaces a banner.
struct HeartbeatStore: Sendable {
    struct Heartbeat: Codable, Equatable {
        let state: String
        let timestamp: Date
    }

    let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let support = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask)[0]
            try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            self.fileURL = support.appendingPathComponent("heartbeat.json")
        }
    }

    func record(_ state: RecorderState) {
        let heartbeat = Heartbeat(state: state.rawValue, timestamp: Date())
        guard let data = try? JSONEncoder().encode(heartbeat) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    func read() -> Heartbeat? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(Heartbeat.self, from: data)
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    var indicatesUncleanShutdown: Bool {
        guard let heartbeat = read() else { return false }
        return heartbeat.state != RecorderState.idle.rawValue
    }
}

enum OrphanSalvager {
    /// Salvage everything readable from CAFs a dead process left behind; remove the CAFs
    /// either way (an unreadable CAF has nothing to recover).
    static func salvage(store: SegmentStore) -> [URL] {
        var salvaged: [URL] = []
        for caf in store.orphanedCAFs() {
            let m4a = caf.deletingPathExtension().appendingPathExtension("m4a")
            do {
                try CAFSegmentWriter.transcodeToM4A(caf: caf, m4a: m4a)
                salvaged.append(m4a)
            } catch {
                try? FileManager.default.removeItem(at: m4a)   // partial output, if any
            }
            try? FileManager.default.removeItem(at: caf)
        }
        return salvaged
    }
}

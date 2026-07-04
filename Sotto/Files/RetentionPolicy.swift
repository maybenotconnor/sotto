import Foundation

/// SPEC "File output" retention: audio default = delete after transcription; transcripts
/// keep forever (nothing here ever touches .md/_day.json).
enum AudioRetention: String, Codable, CaseIterable, Sendable {
    case deleteAfterTranscription
    case keepSevenDays
    case keepForever
}

struct SettingsStore: Sendable {
    // UserDefaults isn't marked Sendable on this SDK, but it is documented as internally
    // thread-safe (all instance methods may be called from any thread) — nonisolated(unsafe)
    // is safe here, matching the DayIndexStore ISO8601DateFormatter precedent.
    nonisolated(unsafe) let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var audioRetention: AudioRetention {
        get {
            defaults.string(forKey: "audioRetention")
                .flatMap(AudioRetention.init(rawValue:)) ?? .deleteAfterTranscription
        }
        nonmutating set {
            defaults.set(newValue.rawValue, forKey: "audioRetention")
        }
    }
}

/// M6b's Settings screen binds to these (ranges are UI-enforced there, not here). Settings
/// changes apply on the NEXT Start/launch — SPEC "changes affect only future segments", not
/// a listening session already in progress.
extension SettingsStore {
    /// Clamped at this getter choke point: corrupted/edited UserDefaults values (e.g. via
    /// the Simulator's `defaults write` or a synced-but-stale plist) must never reach
    /// RecorderStateMachine's preconditions — that would crash-loop before any UI can recover.
    var vadThreshold: Float {
        get {
            guard defaults.object(forKey: "vadThreshold") != nil else { return 0.6 }
            let value = defaults.float(forKey: "vadThreshold")
            guard value.isFinite else { return 0.6 }
            return min(max(value, 0.1), 0.9)
        }
        nonmutating set { defaults.set(newValue, forKey: "vadThreshold") }
    }

    var silenceTimeout: TimeInterval {
        get {
            guard defaults.object(forKey: "silenceTimeout") != nil else { return 45 }
            let value = defaults.double(forKey: "silenceTimeout")
            guard value.isFinite else { return 45 }
            return min(max(value, 15), 120)
        }
        nonmutating set { defaults.set(newValue, forKey: "silenceTimeout") }
    }

    var minSegmentSpeech: TimeInterval {
        get {
            guard defaults.object(forKey: "minSegmentSpeech") != nil else { return 3 }
            let value = defaults.double(forKey: "minSegmentSpeech")
            guard value.isFinite else { return 3 }
            return min(max(value, 1), 10)
        }
        nonmutating set { defaults.set(newValue, forKey: "minSegmentSpeech") }
    }

    var preRollSeconds: TimeInterval {
        get {
            guard defaults.object(forKey: "preRollSeconds") != nil else { return 1.0 }
            let value = defaults.double(forKey: "preRollSeconds")
            guard value.isFinite else { return 1.0 }
            return min(max(value, 0.5), 3.0)
        }
        nonmutating set { defaults.set(newValue, forKey: "preRollSeconds") }
    }

    var wifiOnlyUpload: Bool {
        get {
            defaults.object(forKey: "wifiOnlyUpload") == nil
                ? true : defaults.bool(forKey: "wifiOnlyUpload")
        }
        nonmutating set { defaults.set(newValue, forKey: "wifiOnlyUpload") }
    }

    /// M6b settings toggle; Task 1's provider closure already requires a Keychain key before
    /// picking Deepgram — this adds the explicit user-facing opt-in on top of that.
    var deepgramEnabled: Bool {
        get {
            defaults.object(forKey: "deepgramEnabled") == nil
                ? false : defaults.bool(forKey: "deepgramEnabled")
        }
        nonmutating set { defaults.set(newValue, forKey: "deepgramEnabled") }
    }

    /// M6b onboarding gate: `bool(forKey:)` already returns false when unset, which is
    /// exactly the "not yet completed" default for a fresh install — no clamp needed.
    var hasCompletedOnboarding: Bool {
        get { defaults.bool(forKey: "hasCompletedOnboarding") }
        nonmutating set { defaults.set(newValue, forKey: "hasCompletedOnboarding") }
    }
}

enum RetentionEnforcer {
    /// Post-transcription hook: returns true when the audio was deleted.
    static func applyAfterTranscription(m4aURL: URL, retention: AudioRetention) -> Bool {
        guard retention == .deleteAfterTranscription else { return false }
        return (try? FileManager.default.removeItem(at: m4aURL)) != nil
    }

    /// Launch sweep for keepSevenDays: deletes m4a older than 7 days THAT HAVE a sibling
    /// .md (never deletes untranscribed audio). Returns deleted URLs.
    static func sweep(root: URL, retention: AudioRetention, now: Date = Date()) -> [URL] {
        guard retention == .keepSevenDays else { return [] }
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.creationDateKey]) else { return [] }
        var deleted: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "m4a" {
            let md = url.deletingPathExtension().appendingPathExtension("md")
            guard FileManager.default.fileExists(atPath: md.path) else { continue }   // never delete untranscribed
            let created = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? now
            guard now.timeIntervalSince(created) > 7 * 86_400 else { continue }
            if (try? FileManager.default.removeItem(at: url)) != nil {
                deleted.append(url)
            }
        }
        return deleted
    }
}

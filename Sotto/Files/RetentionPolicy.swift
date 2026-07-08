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

/// Single source of truth for the Advanced listening settings' valid ranges and defaults.
/// BOTH the Settings UI (Stepper/Slider `in:` ranges) and the `SettingsStore` getter clamps
/// below read from here, so the two can never drift apart — raising a maximum in one place
/// automatically applies to the other. Values are seconds except `vadThreshold` (0–1).
enum SettingsBounds {
    static let vadThreshold: ClosedRange<Float> = 0.1...0.9
    static let vadThresholdDefault: Float = 0.6

    static let silenceTimeout: ClosedRange<TimeInterval> = 15...600
    static let silenceTimeoutDefault: TimeInterval = 45

    static let minSegmentSpeech: ClosedRange<TimeInterval> = 1...60
    static let minSegmentSpeechDefault: TimeInterval = 3

    static let preRollSeconds: ClosedRange<TimeInterval> = 0.5...3.0
    static let preRollSecondsDefault: TimeInterval = 1.0
}

extension ClosedRange {
    /// Pins `value` into the range — the clamp used at every SettingsStore getter choke point.
    func clamping(_ value: Bound) -> Bound {
        Swift.min(Swift.max(value, lowerBound), upperBound)
    }
}

/// M6b's Settings screen binds to these (ranges are UI-enforced there too, via SettingsBounds).
/// Settings changes apply on the NEXT Start/launch — SPEC "changes affect only future
/// segments", not a listening session already in progress.
extension SettingsStore {
    /// Clamped at this getter choke point: corrupted/edited UserDefaults values (e.g. via
    /// the Simulator's `defaults write` or a synced-but-stale plist) must never reach
    /// RecorderStateMachine's preconditions — that would crash-loop before any UI can recover.
    var vadThreshold: Float {
        get {
            guard defaults.object(forKey: "vadThreshold") != nil else { return SettingsBounds.vadThresholdDefault }
            let value = defaults.float(forKey: "vadThreshold")
            guard value.isFinite else { return SettingsBounds.vadThresholdDefault }
            return SettingsBounds.vadThreshold.clamping(value)
        }
        nonmutating set { defaults.set(newValue, forKey: "vadThreshold") }
    }

    var silenceTimeout: TimeInterval {
        get {
            guard defaults.object(forKey: "silenceTimeout") != nil else { return SettingsBounds.silenceTimeoutDefault }
            let value = defaults.double(forKey: "silenceTimeout")
            guard value.isFinite else { return SettingsBounds.silenceTimeoutDefault }
            return SettingsBounds.silenceTimeout.clamping(value)
        }
        nonmutating set { defaults.set(newValue, forKey: "silenceTimeout") }
    }

    var minSegmentSpeech: TimeInterval {
        get {
            guard defaults.object(forKey: "minSegmentSpeech") != nil else { return SettingsBounds.minSegmentSpeechDefault }
            let value = defaults.double(forKey: "minSegmentSpeech")
            guard value.isFinite else { return SettingsBounds.minSegmentSpeechDefault }
            return SettingsBounds.minSegmentSpeech.clamping(value)
        }
        nonmutating set { defaults.set(newValue, forKey: "minSegmentSpeech") }
    }

    var preRollSeconds: TimeInterval {
        get {
            guard defaults.object(forKey: "preRollSeconds") != nil else { return SettingsBounds.preRollSecondsDefault }
            let value = defaults.double(forKey: "preRollSeconds")
            guard value.isFinite else { return SettingsBounds.preRollSecondsDefault }
            return SettingsBounds.preRollSeconds.clamping(value)
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

    /// iCloud backup phase (design 2026-07-07): whether finalized transcripts mirror to the
    /// app's iCloud ubiquity container. Default ON (opt-out) — Sotto is an ambient recorder,
    /// so the "don't lose your data on a new phone" safety net protects the majority who never
    /// open Settings; `object(forKey:) == nil` distinguishes "never set" (→ true) from an
    /// explicit false, matching the wifiOnlyUpload precedent above.
    var iCloudBackupEnabled: Bool {
        get {
            defaults.object(forKey: "iCloudBackupEnabled") == nil
                ? true : defaults.bool(forKey: "iCloudBackupEnabled")
        }
        nonmutating set { defaults.set(newValue, forKey: "iCloudBackupEnabled") }
    }

    /// M10 engine picker (supersedes M6b's "Use Deepgram" bool). Reads the legacy
    /// `deepgramEnabled` key as a migration fallback so pre-M10 installs keep their choice;
    /// writes only the new key. AppModel's provider closure still requires a Keychain key
    /// before actually picking Deepgram — this is the user's *preference*, not a guarantee.
    var transcriptionEngine: TranscriptionBackend {
        get {
            if let raw = defaults.string(forKey: "transcriptionEngine"),
               let engine = TranscriptionBackend(rawValue: raw) {
                return engine
            }
            return defaults.bool(forKey: "deepgramEnabled") ? .deepgram : .speechAnalyzer
        }
        nonmutating set { defaults.set(newValue.rawValue, forKey: "transcriptionEngine") }
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

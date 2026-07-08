import SwiftUI
import UIKit
import UserNotifications

/// SPEC "Settings": Listening / Transcription / Storage / Notifications / About & Legal.
struct SettingsView: View {
    let model: AppModel

    @State private var vadThreshold: Float = SettingsBounds.vadThresholdDefault
    @State private var silenceTimeout: Double = SettingsBounds.silenceTimeoutDefault
    @State private var minSegment: Double = SettingsBounds.minSegmentSpeechDefault
    @State private var preRoll: Double = SettingsBounds.preRollSecondsDefault
    @State private var retention: AudioRetention = .deleteAfterTranscription
    @State private var engine: TranscriptionBackend = .speechAnalyzer
    @State private var wifiOnly = true
    @State private var deepgramKey = ""
    @State private var keyTestResult: Bool?
    @State private var usage: AppModel.StorageUsage?
    @State private var showPowerUser = false
    @State private var notificationStatus = "—"
    @State private var iCloudBackupEnabled = true
    @State private var iCloudStatus = "—"
    @State private var iCloudHasBackups = false
    @State private var backupResult: String?
    @State private var restoreResult: String?
    @State private var showRemoveBackupConfirm = false
    @State private var showPairSheet = false
    @State private var showForgetConfirm = false

    var body: some View {
        Form {
            listeningSection
            omiSection
            transcriptionSection
            storageSection
            backupSection
            notificationsSection
            aboutSection
        }
        .navigationTitle("Settings")
        .sheet(isPresented: $showPairSheet) { OmiPairSheet(model: model) }
        .task {
            let settings = model.settings
            vadThreshold = settings.vadThreshold
            silenceTimeout = settings.silenceTimeout
            minSegment = settings.minSegmentSpeech
            preRoll = settings.preRollSeconds
            retention = settings.audioRetention
            engine = settings.transcriptionEngine
            wifiOnly = settings.wifiOnlyUpload
            iCloudBackupEnabled = settings.iCloudBackupEnabled
            iCloudStatus = await model.iCloudAvailable()
                ? "Backed up to iCloud"
                : "iCloud unavailable — sign in to iCloud in Settings"
            iCloudHasBackups = await model.iCloudHasBackups()
            deepgramKey = KeychainStore().get("deepgramAPIKey") ?? ""
            usage = model.storageUsage()
            let notificationSettings = await UNUserNotificationCenter.current().notificationSettings()
            notificationStatus = switch notificationSettings.authorizationStatus {
            case .authorized: "On"
            case .provisional: "Quiet delivery"
            case .denied: "Off"
            default: "Not requested"
            }
        }
    }

    private var listeningSection: some View {
        Section("Listening") {
            if let name = model.pairedOmiName {
                LabeledContent("Audio source", value: "\(name) + iPhone mic fallback")
            } else {
                LabeledContent("Audio source", value: "iPhone microphone")
            }
            DisclosureGroup("Advanced", isExpanded: $showPowerUser) {
                VStack(alignment: .leading) {
                    Text("Speech sensitivity")
                    Slider(value: $vadThreshold, in: SettingsBounds.vadThreshold) { Text("Sensitivity") }
                        minimumValueLabel: { Text("Sensitive").font(.caption2) }
                        maximumValueLabel: { Text("Strict").font(.caption2) }
                        .onChange(of: vadThreshold) { _, value in model.settings.vadThreshold = value }
                    Button("Reset to default") {
                        vadThreshold = SettingsBounds.vadThresholdDefault
                        model.settings.vadThreshold = SettingsBounds.vadThresholdDefault
                    }
                        .font(.footnote)
                }
                Stepper("Silence timeout: \(Int(silenceTimeout)) s",
                        value: $silenceTimeout, in: SettingsBounds.silenceTimeout, step: 5)
                    .onChange(of: silenceTimeout) { _, value in model.settings.silenceTimeout = value }
                Stepper("Pre-roll: \(preRoll, format: .number.precision(.fractionLength(1))) s",
                        value: $preRoll, in: SettingsBounds.preRollSeconds, step: 0.5)
                    .onChange(of: preRoll) { _, value in model.settings.preRollSeconds = value }
                Stepper("Min segment: \(Int(minSegment)) s", value: $minSegment, in: SettingsBounds.minSegmentSpeech)
                    .onChange(of: minSegment) { _, value in model.settings.minSegmentSpeech = value }
                Text("Changes apply after the app next launches.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// M12 Settings (Task 11): pairing status + pair/forget actions for an Omi wearable.
    /// This section's device/status/battery readout always reflects the pairing store
    /// immediately (`AppModel.pairOmi`/`forgetOmi` set it right away) — but the pipeline's
    /// ACTUAL audio source only recomposes right away if nothing is listening
    /// (`AppModel.rebuildPipelineIfIdle`); otherwise the swap is deferred until the current
    /// session ends (`AppModel.stopListening` → `rebuildIfSourceShapeChanged`, M12 final
    /// review Important #2) — mirrors the existing "Changes apply..." convention used for the
    /// Advanced listening settings above.
    private var omiSection: some View {
        Section("Omi Device") {
            if let name = model.pairedOmiName {
                LabeledContent("Device", value: name)
                LabeledContent("Status", value: omiStatusLabel)
                if let battery = model.omiBatteryLevel {
                    LabeledContent("Battery", value: "\(battery)%")
                }
                if let failure = model.omiSetupFailure {
                    Text(failure).font(.caption).foregroundStyle(.red)
                }
                Button("Forget This Device", role: .destructive) { showForgetConfirm = true }
                    .confirmationDialog("Forget \(name)?", isPresented: $showForgetConfirm) {
                        Button("Forget", role: .destructive) { Task { await model.forgetOmi() } }
                    } message: {
                        Text("Sotto will stop connecting to it and use the iPhone microphone.")
                    }
                Text("Sotto switches to using it right away if nothing's listening, otherwise once the current session ends.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Button("Pair Omi Device…") { showPairSheet = true }
                Text("Wear an Omi pendant and Sotto records from it automatically, falling back to the iPhone mic when it's out of range.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var omiStatusLabel: String {
        switch model.omiConnectionState {
        case .streaming: "Streaming"
        case .connected: "Connected"
        case .connecting: "Connecting…"
        case .disconnected, nil: "Not connected"
        case .unavailable(.poweredOff): "Bluetooth is off"
        case .unavailable(.unauthorized): "Bluetooth permission needed"
        case .unavailable(.unsupported): "Bluetooth unavailable"
        }
    }

    private var transcriptionSection: some View {
        Section("Transcription") {
            // M10: engine choice is a Picker, not a toggle — the setting is a selection
            // between engines (and leaves room for more), not an on/off feature.
            Picker("Engine", selection: $engine) {
                Text("On-device").tag(TranscriptionBackend.speechAnalyzer)
                Text("Deepgram (cloud)").tag(TranscriptionBackend.deepgram)
            }
            .onChange(of: engine) { _, value in model.settings.transcriptionEngine = value }
            if engine == .speechAnalyzer {
                HStack {
                    Label("On-device model", systemImage: "iphone")
                    Spacer()
                    switch model.assetState {
                    case .installed: Text("Installed").foregroundStyle(.secondary)
                    case .downloading(let fraction): ProgressView(value: fraction).frame(width: 80)
                    case .unsupported: Text("Unavailable on this device").foregroundStyle(.secondary)
                    default: Button("Download") { Task { await model.downloadSpeechModel() } }
                    }
                }
            }
            if engine == .deepgram {
                SecureField("Deepgram API key", text: $deepgramKey)
                    .onChange(of: deepgramKey) { _, _ in keyTestResult = nil }
                    .onSubmit { persistKey() }
                HStack {
                    Button("Test key") {
                        Task {
                            persistKey()   // testing an untyped-submitted key must still work
                            keyTestResult = await model.testDeepgramKey(deepgramKey)
                        }
                    }
                    .buttonStyle(.bordered)   // Form buttons render as bare text; the border
                                              // keeps it reading as a button even when disabled
                    .disabled(deepgramKey.isEmpty)
                    if let result = keyTestResult {
                        Image(systemName: result ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(result ? .green : .red)
                    }
                }
                if deepgramKey.isEmpty {
                    // Surfaces the runtime's silent fallback (AppModel's provider requires a
                    // key) — without this the picker would look like it's doing something
                    // that it isn't.
                    Label("No API key — on-device transcription is used until a key is added.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
                Toggle("Wi-Fi only uploads", isOn: $wifiOnly)
                    .onChange(of: wifiOnly) { _, value in model.settings.wifiOnlyUpload = value }
                Text("Audio is sent to Deepgram under your account; training opt-out is always sent.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var storageSection: some View {
        Section("Storage") {
            Picker("Keep audio", selection: $retention) {
                Text("Delete after transcription").tag(AudioRetention.deleteAfterTranscription)
                Text("Keep 7 days").tag(AudioRetention.keepSevenDays)
                Text("Keep forever").tag(AudioRetention.keepForever)
            }
            .onChange(of: retention) { _, value in model.settings.audioRetention = value }
            if let usage {
                // LabeledContent's `value:` is a plain String (not a LocalizedStringKey), so
                // the `Text`-style "\(_, format:)" interpolation doesn't resolve here
                // ("extra argument 'format' in call") — format via `.formatted(_:)` instead.
                LabeledContent("Audio", value: usage.audioMB.formatted(.number.precision(.fractionLength(1))) + " MB")
                LabeledContent("Transcripts", value: usage.transcriptKB.formatted(.number.precision(.fractionLength(0))) + " KB")
            }
            Text("Your recordings live in Files ▸ On My iPhone ▸ Sotto.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Backup & Restore (design 2026-07-07). iCloud controls only this phase; the "additional
    /// backup providers" dropdown lands with the WebDAV phase (YAGNI — no empty dropdown now).
    private var backupSection: some View {
        Section("Backup & Restore") {
            Toggle("Back up transcripts to iCloud", isOn: $iCloudBackupEnabled)
                .onChange(of: iCloudBackupEnabled) { _, value in
                    model.settings.iCloudBackupEnabled = value
                }
            Text("Transcripts (not audio) are backed up to your iCloud so you don't lose them if you get a new phone. Your recordings stay on this device.")
                .font(.caption).foregroundStyle(.secondary)

            LabeledContent("Status", value: iCloudStatus)

            Button("Back up now") {
                backupResult = "Backing up…"
                Task {
                    let n = await model.backupAllToICloud()
                    backupResult = "Backed up \(n) transcript\(n == 1 ? "" : "s")."
                    iCloudHasBackups = await model.iCloudHasBackups()
                }
            }
            if let backupResult {
                Text(backupResult).font(.caption).foregroundStyle(.secondary)
            }

            Button("Restore from iCloud") {
                restoreResult = "Restoring…"
                Task {
                    let n = await model.restoreFromICloud()
                    restoreResult = n > 0
                        ? "Restored \(n) transcript\(n == 1 ? "" : "s")."
                        : "Nothing new to restore."
                }
            }
            if let restoreResult {
                Text(restoreResult).font(.caption).foregroundStyle(.secondary)
            }

            // Shown only when the container actually holds transcripts — so "stop backing up"
            // (the toggle, non-destructive) can never be confused with "delete my backup".
            if iCloudHasBackups {
                Button("Remove iCloud backup", role: .destructive) { showRemoveBackupConfirm = true }
                    .confirmationDialog("Remove all transcripts from iCloud?",
                                        isPresented: $showRemoveBackupConfirm) {
                        Button("Remove", role: .destructive) {
                            Task {
                                await model.removeICloudBackup()
                                iCloudHasBackups = false
                                backupResult = "Removed iCloud backup."
                            }
                        }
                    } message: {
                        Text("This deletes your backed-up transcripts from iCloud. Transcripts on this device are not affected.")
                    }
                Text("Turning off the toggle just stops backing up — your existing iCloud copies stay. Use this to remove them.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var notificationsSection: some View {
        Section("Notifications") {
            LabeledContent("Paused-listening alerts", value: notificationStatus)
            Text("When a phone call interrupts listening, Sotto sends a quiet notification so you know it's no longer recording.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Open notification settings") {
                if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .font(.footnote)
        }
    }

    /// Writes (or clears) the Deepgram key in the Keychain. Called on submit rather than on
    /// every keystroke — Keychain access is comparatively expensive and per-character writes
    /// were firing on each typed character — and again from the Test-key button so testing a
    /// key that was typed but never explicitly submitted still exercises the current text.
    private func persistKey() {
        if deepgramKey.isEmpty { KeychainStore().delete("deepgramAPIKey") }
        else { KeychainStore().set(deepgramKey, for: "deepgramAPIKey") }
    }

    private var aboutSection: some View {
        Section("About & Legal") {
            NavigationLink("Recording laws — know your responsibility") {
                LegalSummaryView()
            }
            LabeledContent("Licenses", value: "FluidAudio (Apache-2.0), Silero (MIT)")
                .font(.footnote)
        }
    }
}

/// SPEC onboarding/legal: one-party vs all-party summary + 50-state pointer.
struct LegalSummaryView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("You are responsible for recording lawfully.")
                    .font(.headline)
                Text("""
                Federal law and most US states allow recording conversations you take part in \
                (one-party consent). Around 11 states — including California, Florida, \
                Massachusetts, Pennsylvania, Washington and Illinois — require ALL parties to \
                consent, and Oregon requires all-party consent for in-person conversations. \
                Phone calls stop Sotto automatically. Don't leave your phone recording in a \
                room you're not in. Laws differ by state — check a 50-state survey (e.g. \
                Justia's recording-law summary) before relying on a recording.
                """)
                .font(.callout)
            }
            .padding()
        }
        .navigationTitle("Recording laws")
    }
}

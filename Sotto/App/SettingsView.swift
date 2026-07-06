import SwiftUI
import UIKit
import UserNotifications
import UniformTypeIdentifiers

/// SPEC "Settings": Listening / Transcription / Storage / Notifications / About & Legal.
struct SettingsView: View {
    let model: AppModel

    @State private var vadThreshold: Float = 0.6
    @State private var silenceTimeout: Double = 45
    @State private var minSegment: Double = 3
    @State private var preRoll: Double = 1.0
    @State private var retention: AudioRetention = .deleteAfterTranscription
    @State private var engine: TranscriptionBackend = .speechAnalyzer
    @State private var wifiOnly = true
    @State private var deepgramKey = ""
    @State private var keyTestResult: Bool?
    @State private var usage: AppModel.StorageUsage?
    @State private var showPowerUser = false
    @State private var notificationStatus = "—"
    @State private var showSyncFolderPicker = false
    @State private var syncFolderName: String?
    @State private var exportAllResult: String?

    var body: some View {
        Form {
            listeningSection
            transcriptionSection
            storageSection
            notificationsSection
            aboutSection
        }
        .navigationTitle("Settings")
        .fileImporter(isPresented: $showSyncFolderPicker, allowedContentTypes: [.folder]) { result in
            guard case .success(let url) = result else { return }
            do {
                try SyncDestinationStore().save(url: url)
                syncFolderName = SyncDestinationStore().displayName
            } catch {
                exportAllResult = "Couldn't save that folder — try picking it again."
            }
        }
        .task {
            let settings = model.settings
            vadThreshold = settings.vadThreshold
            silenceTimeout = settings.silenceTimeout
            minSegment = settings.minSegmentSpeech
            preRoll = settings.preRollSeconds
            retention = settings.audioRetention
            engine = settings.transcriptionEngine
            wifiOnly = settings.wifiOnlyUpload
            deepgramKey = KeychainStore().get("deepgramAPIKey") ?? ""
            usage = model.storageUsage()
            syncFolderName = SyncDestinationStore().displayName
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
            LabeledContent("Audio source", value: "Phone microphone")
            DisclosureGroup("Advanced", isExpanded: $showPowerUser) {
                VStack(alignment: .leading) {
                    Text("Speech sensitivity")
                    Slider(value: $vadThreshold, in: 0.1...0.9) { Text("Sensitivity") }
                        minimumValueLabel: { Text("Sensitive").font(.caption2) }
                        maximumValueLabel: { Text("Strict").font(.caption2) }
                        .onChange(of: vadThreshold) { _, value in model.settings.vadThreshold = value }
                    Button("Reset to default") { vadThreshold = 0.6; model.settings.vadThreshold = 0.6 }
                        .font(.footnote)
                }
                Stepper("Silence timeout: \(Int(silenceTimeout)) s", value: $silenceTimeout, in: 15...120, step: 5)
                    .onChange(of: silenceTimeout) { _, value in model.settings.silenceTimeout = value }
                Stepper("Pre-roll: \(preRoll, format: .number.precision(.fractionLength(1))) s",
                        value: $preRoll, in: 0.5...3.0, step: 0.5)
                    .onChange(of: preRoll) { _, value in model.settings.preRollSeconds = value }
                Stepper("Min segment: \(Int(minSegment)) s", value: $minSegment, in: 1...10)
                    .onChange(of: minSegment) { _, value in model.settings.minSegmentSpeech = value }
                Text("Changes apply after the app next launches.")
                    .font(.caption).foregroundStyle(.secondary)
            }
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
                Text("~$0.26/hr, ~$0.38/hr with diarization, billed to your Deepgram account.")
                    .font(.caption).foregroundStyle(.secondary)
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

            // M11 cloud sync: clone finalized conversations into any Files-provider folder.
            if let syncFolderName {
                LabeledContent("Cloud sync folder", value: syncFolderName)
                Text("New conversations are copied to this folder automatically after each transcription — nothing to press.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Export all now") {
                    exportAllResult = "Exporting…"
                    Task {
                        let copied = await model.exportAllToSyncDestination()
                        exportAllResult = copied.map { "Copied \($0) file(s)." }
                            ?? "Folder unavailable — pick it again."
                    }
                }
                Text("\"Export all now\" is a one-time catch-up: it copies conversations recorded before you set this folder.")
                    .font(.caption).foregroundStyle(.secondary)
                if let exportAllResult {
                    Text(exportAllResult).font(.caption).foregroundStyle(.secondary)
                }
                Button("Stop syncing", role: .destructive) {
                    SyncDestinationStore().clear()
                    self.syncFolderName = nil
                    exportAllResult = nil
                }
                Text("Deleting a conversation in Sotto doesn't remove copies already in this folder.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Button("Set cloud sync folder…") { showSyncFolderPicker = true }
                Text("New conversations are copied there after transcription — works with iCloud Drive, Google Drive, OpenCloud, and any Files provider.")
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

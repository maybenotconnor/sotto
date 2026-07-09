import SwiftUI

/// WebDAV backup configuration (design 2026-07-09 §5): the first "additional backup
/// provider" behind the sink seam. URL + username live in SettingsStore; the app password
/// lives in the Keychain. Save is explicit (a button), never per-keystroke — the
/// persistKey() lesson. Test connection is an affordance, not a gate on saving.
struct WebDAVSettingsView: View {
    let model: AppModel

    @State private var serverURL = ""
    @State private var username = ""
    @State private var appPassword = ""
    @State private var enabled = true
    @State private var audioBackup = false
    @State private var configured = false
    @State private var formNote: String?
    @State private var statusLine = "—"
    @State private var backupResult: String?
    @State private var restoreResult: String?
    @State private var showForgetConfirm = false

    var body: some View {
        Form {
            serverSection
            if configured {
                optionsSection
                actionsSection
                forgetSection
            }
        }
        .navigationTitle("WebDAV server")
        .task { await load() }
    }

    private func load() async {
        let settings = model.settings
        serverURL = settings.webdavServerURL ?? ""
        username = settings.webdavUsername ?? ""
        appPassword = KeychainStore().get(WebDAVConfig.passwordKeychainKey) ?? ""
        enabled = settings.webdavEnabled
        audioBackup = settings.webdavAudioBackup
        configured = WebDAVConfig.load(settings: settings) != nil
        statusLine = Self.describe(await model.webdavStatus())
    }

    private var serverSection: some View {
        Section("Server") {
            TextField("https://cloud.example.com/…", text: $serverURL)
                .keyboardType(.URL)
                .textContentType(.URL)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            TextField("Username", text: $username)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            SecureField("App password", text: $appPassword)
            Button("Save") { save() }
            Button("Test connection") { Task { await testConnection() } }
                .disabled(!configured)
            if let formNote {
                Text(formNote).font(.caption).foregroundStyle(.secondary)
            }
            Text("Paste the WebDAV URL of the folder backups should land in — day folders are created directly inside it. Generate an app password in your server's security settings.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// HTTPS-only enforced HERE with copy, not just silently at WebDAVConfig.load — a
    /// plain-http URL should fail loudly at save, not mysteriously at request time.
    private func save() {
        let trimmedURL = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUser = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmedURL), url.scheme?.lowercased() == "https" else {
            formNote = "Enter an https:// URL — Sotto only connects over TLS."
            return
        }
        guard !trimmedUser.isEmpty, !appPassword.isEmpty else {
            formNote = "Username and app password are required."
            return
        }
        model.settings.webdavServerURL = trimmedURL
        model.settings.webdavUsername = trimmedUser
        KeychainStore().set(appPassword, for: WebDAVConfig.passwordKeychainKey)
        configured = WebDAVConfig.load(settings: model.settings) != nil
        formNote = "Saved."
    }

    private func testConnection() async {
        formNote = "Testing…"
        formNote = switch await model.testWebDAVConnection() {
        case .connected:
            "Connected."
        case .unauthorized:
            "Server reached, but username or app password was rejected."
        case .notFound:
            "Folder not found — check the URL or create the folder on your server."
        case .failed(let reason):
            "Connection failed — \(reason)."
        }
    }

    private var optionsSection: some View {
        Section("Options") {
            Toggle("Back up to this server", isOn: $enabled)
                .onChange(of: enabled) { _, value in model.settings.webdavEnabled = value }
            Toggle("Also back up audio", isOn: $audioBackup)
                .onChange(of: audioBackup) { _, value in model.settings.webdavAudioBackup = value }
            Text("Transcripts (and audio, if enabled) are copied to your own server. Nothing else leaves this device. Turning backup off pauses it — files already on the server stay.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var actionsSection: some View {
        Section("Actions") {
            LabeledContent("Status", value: statusLine)
            Button("Back up now") {
                backupResult = "Backing up…"
                Task {
                    let counts = await model.backupAllToWebDAV()
                    let t = counts.transcripts, a = counts.audio
                    backupResult = audioBackup
                        ? "Backed up \(t) transcript\(t == 1 ? "" : "s"), \(a) audio file\(a == 1 ? "" : "s")."
                        : "Backed up \(t) transcript\(t == 1 ? "" : "s")."
                    statusLine = Self.describe(await model.webdavStatus())
                }
            }
            if let backupResult {
                Text(backupResult).font(.caption).foregroundStyle(.secondary)
            }
            Button("Restore from server") {
                restoreResult = "Restoring…"
                Task {
                    let n = await model.restoreFromWebDAV()
                    restoreResult = n > 0
                        ? "Restored \(n) transcript\(n == 1 ? "" : "s")."
                        : "Nothing new to restore."
                }
            }
            if let restoreResult {
                Text(restoreResult).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var forgetSection: some View {
        Section {
            Button("Forget this server", role: .destructive) { showForgetConfirm = true }
                .confirmationDialog("Forget this server?", isPresented: $showForgetConfirm) {
                    Button("Forget", role: .destructive) { forget() }
                } message: {
                    Text("Removes the server settings and app password from this device. Files already on the server are not touched.")
                }
        }
    }

    /// Clears local config only — deliberately NO destructive remote wipe (design §2:
    /// the user fully controls their own server, unlike the invisible iCloud container).
    private func forget() {
        model.settings.webdavServerURL = nil
        model.settings.webdavUsername = nil
        model.settings.webdavEnabled = true        // back to defaults
        model.settings.webdavAudioBackup = false
        KeychainStore().delete(WebDAVConfig.passwordKeychainKey)
        serverURL = ""; username = ""; appPassword = ""
        enabled = true; audioBackup = false
        configured = false
        backupResult = nil; restoreResult = nil
        formNote = "Server forgotten."
    }

    /// Status-line copy for the executor's last outcome (design §5).
    static func describe(_ status: WebDAVStatus) -> String {
        switch status {
        case .idle:
            "No backups attempted yet"
        case .ok(let date):
            "Last backup \(date.formatted(date: .omitted, time: .shortened))"
        case .skippedWiFi:
            "Skipped — waiting for Wi-Fi"
        case .failed(let reason, _):
            "Failed — \(reason)"
        }
    }
}

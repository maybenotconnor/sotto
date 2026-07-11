import AVFAudio
import SwiftUI
import UserNotifications

/// SPEC "Onboarding": 4 cards + mic/notification prompts + model download card.
struct OnboardingView: View {
    let model: AppModel
    let onComplete: () -> Void
    @State private var page = 0
    @State private var consented = false

    var body: some View {
        TabView(selection: $page) {
            card(
                icon: "waveform.circle.fill", tint: .green,
                title: "Your notetaker that starts itself",
                body: "Sotto notices when a conversation starts and takes notes automatically — no record button to remember. Recording and transcription stay on your phone by default.",
                button: "Continue") { page = 1 }
                .tag(0)
            card(
                icon: "eye.circle.fill", tint: .orange,
                title: "Always visible",
                body: "While listening you'll always see the orange mic indicator and a lock-screen Live Activity, so recording is never invisible.",
                button: "Continue") { page = 2 }
                .tag(1)
            consentCard.tag(2)
            permissionsCard.tag(3)
            modelCard.tag(4)
        }
        .tabViewStyle(.page)
        .indexViewStyle(.page(backgroundDisplayMode: .always))
        .interactiveDismissDisabled()
    }

    private var consentCard: some View {
        card(
            icon: "checkmark.shield.fill", tint: .blue,
            title: "Your responsibility",
            body: "Most US states let you record conversations you're part of; about 11 (and Oregon, for in-person talk) require everyone's consent. Phone calls stop Sotto automatically. Laws differ by state — the Settings screen links a 50-state summary.",
            button: "I understand") {
                consented = true
                page = 3
            }
    }

    private var permissionsCard: some View {
        card(
            icon: "mic.circle.fill", tint: .red,
            title: "Permissions",
            body: "Sotto needs the microphone to listen, and uses quiet notifications to tell you when a phone call paused listening.",
            button: "Allow access") {
                Task {
                    _ = await AVAudioApplication.requestRecordPermission()
                    _ = try? await UNUserNotificationCenter.current()
                        .requestAuthorization(options: [.alert])
                    page = 4
                }
            }
    }

    private var modelCard: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "arrow.down.circle.fill").font(.system(size: 56)).foregroundStyle(.tint)
            Text("On-device transcription").font(.title2.bold())
            switch model.assetState {
            case .installed:
                Text("The speech model is already installed.").multilineTextAlignment(.center)
                Button("Start using Sotto") { completeIfConsented() }.inkProminent()
            case .downloading(let fraction):
                ProgressView(value: fraction).padding(.horizontal, 48)
                Text("Downloading the speech model…").font(.footnote).foregroundStyle(.secondary)
            case .unsupported:
                Text("This device can't run on-device transcription — recordings still save and transcribe on a supported iPhone.")
                    .multilineTextAlignment(.center).padding(.horizontal)
                Button("Continue") { completeIfConsented() }
                    .inkProminent()
            default:
                Text("Sotto transcribes on this iPhone — nothing leaves your device. The model downloads once.")
                    .multilineTextAlignment(.center).padding(.horizontal)
                Button("Download model") { Task { await model.downloadSpeechModel() } }
                    .inkProminent()
                Button("Skip for now — recordings still save") { completeIfConsented() }
                    .font(.footnote)
            }
            Spacer()
        }
        .padding()
        .onChange(of: model.assetState) { _, state in
            // Assets are frequently pre-installed (shared across app installs on the same
            // device), so this fires the instant the model appears no matter which page the
            // user is actually on — without the page==4 gate it yanks them straight out of
            // the intro cards / permissions prompt before they ever see them.
            if state == .installed && page == 4 { completeIfConsented() }
        }
    }

    /// Guards the only path to `onComplete()`: the consent card's "I understand" is the
    /// intended sole route past the recording-law disclosure, but `TabView(.page)` still lets
    /// a swipe skip straight past it to the permissions/model cards without ever setting
    /// `consented`. Rather than fight the swipe gesture, completion itself checks the flag —
    /// an unconsented user who reaches the model card is bounced back to the consent page
    /// instead of finishing onboarding.
    private func completeIfConsented() {
        if consented {
            onComplete()
        } else {
            page = 2
        }
    }

    private func card(
        icon: String, tint: Color, title: String, body bodyText: String,
        button: String, action: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: icon).font(.system(size: 56)).foregroundStyle(tint)
            Text(title).font(.title2.bold()).multilineTextAlignment(.center)
            Text(bodyText).multilineTextAlignment(.center).padding(.horizontal)
            Button(button, action: action).inkProminent()
            Spacer()
        }
        .padding()
    }
}

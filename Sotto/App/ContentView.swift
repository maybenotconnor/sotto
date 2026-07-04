import AVFAudio
import SwiftUI
import UIKit

/// SPEC "Main screen": one glance = current state; one tap = start/stop.
struct ContentView: View {
    let model: AppModel
    @State private var micDenied = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            Group {
                if let setupError = model.setupError {
                    ContentUnavailableView(
                        "Setup failed",
                        systemImage: "exclamationmark.triangle",
                        description: Text(setupError))
                } else if let pipeline = model.pipeline {
                    MainScreen(model: model, pipeline: pipeline, micDenied: micDenied)
                } else {
                    ProgressView("Preparing…")
                }
            }
            .navigationTitle("Sotto")
        }
        .task {
            await model.ensureSetUp()
            micDenied = AVAudioApplication.shared.recordPermission == .denied
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            micDenied = AVAudioApplication.shared.recordPermission == .denied
            Task { await model.refreshTodaySummary() }
        }
    }
}

private struct MainScreen: View {
    let model: AppModel
    let pipeline: ListeningPipeline
    let micDenied: Bool

    private var isActive: Bool { pipeline.status != .idle }

    var body: some View {
        VStack(spacing: 20) {
            banners
            StateDial(status: pipeline.status)
            Text(stateLabel)
                .font(.title.bold())
                .foregroundStyle(stateColor)
            if let started = pipeline.sessionStartedAt {
                Text(started, style: .timer)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            todaySummary

            startStopButton

            if isActive {
                Text("Listening uses roughly as much battery as music playback.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 12)
    }

    @ViewBuilder
    private var banners: some View {
        if let notice = model.recoveryNotice {
            VStack(spacing: 4) {
                NoticeBanner(text: notice, color: .orange)
                Button("Dismiss") { model.dismissRecoveryNotice() }
                    .font(.footnote)
            }
        }
        if case .downloading(let fraction) = model.assetState {
            VStack(spacing: 4) {
                ProgressView(value: fraction)
                Text("Preparing on-device transcription — recordings are saved and will be transcribed when it's ready.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)
        } else if case .notInstalled = model.assetState {
            Button {
                Task { await model.downloadSpeechModel() }
            } label: {
                Label("Download transcription model", systemImage: "arrow.down.circle")
                    .font(.footnote)
            }
        } else if case .failed = model.assetState {
            VStack(spacing: 4) {
                NoticeBanner(text: "Model download failed — check your connection.", color: .red)
                Button("Try again") { Task { await model.downloadSpeechModel() } }
                    .font(.footnote)
            }
        }
        if micDenied {
            VStack(spacing: 6) {
                NoticeBanner(
                    text: "Microphone access is off. Sotto can't listen without it.",
                    color: .red)
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .font(.footnote.bold())
            }
        }
        if pipeline.diskGuardActive {
            NoticeBanner(text: "Low disk space — new recordings are paused.", color: .red)
        }
    }

    private var todaySummary: some View {
        Group {
            if let summary = model.todaySummary {
                Text("\(summary.count) conversations · \(Int(summary.totalMinutes)) min")
            } else {
                Text("No conversations yet today")
            }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .task(id: pipeline.finalizedCount) {
            await model.refreshTodaySummary()
        }
    }

    private var startStopButton: some View {
        Button {
            Task {
                switch pipeline.status {
                case .idle: await pipeline.start()
                case .interrupted: await pipeline.resumeFromInterruption()
                default: await pipeline.stop()
                }
            }
        } label: {
            Text(buttonLabel)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .tint(isActive ? .red : .accentColor)
        .padding(.horizontal, 40)
        .disabled(micDenied && (pipeline.status == .idle || pipeline.status == .interrupted))
    }

    private var buttonLabel: String {
        switch pipeline.status {
        case .idle: "Start Listening"
        case .interrupted: "Resume"
        default: "Stop"
        }
    }

    private var stateLabel: String {
        switch pipeline.status {
        case .idle: "Idle"
        case .starting: "Starting…"
        case .listening: "Listening"
        case .recording: "Recording"
        case .silence: "Listening"
        case .interrupted: pipeline.haltReason == .userPause ? "Paused by you" : "Paused — call"
        }
    }

    private var stateColor: Color {
        switch pipeline.status {
        case .idle: .secondary
        case .starting: .secondary
        case .listening, .silence: .green
        case .recording: .red
        case .interrupted: .orange
        }
    }
}

/// The spec's "large state dial": a pulsing ring while listening, solid otherwise.
private struct StateDial: View {
    let status: ListeningPipeline.Status
    @State private var pulsing = false

    private var color: Color {
        switch status {
        case .idle, .starting: .secondary.opacity(0.4)
        case .listening, .silence: .green
        case .recording: .red
        case .interrupted: .orange
        }
    }

    private var isLive: Bool {
        switch status {
        case .listening, .recording, .silence: true
        default: false
        }
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(color, lineWidth: 6)
                .frame(width: 140, height: 140)
                .scaleEffect(pulsing && isLive ? 1.06 : 1.0)
                .animation(
                    isLive ? .easeInOut(duration: 1.2).repeatForever(autoreverses: true) : .default,
                    value: pulsing && isLive)
            Image(systemName: status == .recording ? "waveform" : "mic")
                .font(.system(size: 44))
                .foregroundStyle(color)
        }
        .onAppear { pulsing = true }
        .accessibilityHidden(true)
    }
}

private struct NoticeBanner: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(color)
            .multilineTextAlignment(.center)
            .padding(.horizontal)
    }
}

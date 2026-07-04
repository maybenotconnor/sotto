import SwiftUI
import UIKit

struct ContentView: View {
    @State private var pipeline: ListeningPipeline?
    @State private var setupError: String?
    @State private var recoveryNotice: String?
    @State private var setUpStarted = false
    @State private var observer: AudioSessionObserver?

    var body: some View {
        NavigationStack {
            Group {
                if let setupError {
                    ContentUnavailableView(
                        "Setup failed",
                        systemImage: "exclamationmark.triangle",
                        description: Text(setupError))
                } else if let pipeline {
                    PipelineView(pipeline: pipeline, recoveryNotice: recoveryNotice)
                } else {
                    ProgressView("Loading VAD model…")
                }
            }
            .navigationTitle("Sotto")
        }
        .task { await setUp() }
        .onReceive(NotificationCenter.default.publisher(for: .sottoToggleListening)) { _ in
            Task { await pipeline?.toggleFromIntent() }
        }
    }

    @MainActor
    private func setUp() async {
        guard !setUpStarted else { return }
        setUpStarted = true
        guard let modelURL = Bundle.main.url(
            forResource: SileroSpeechDetector.modelResourceName,
            withExtension: "mlmodelc")
        else {
            setupError = "VAD model missing from app bundle"
            return
        }

        let store = SegmentStore()
        let heartbeat = HeartbeatStore()

        // Unconditional launch sweep (SPEC "Recording writer"): a failed finalize can leave
        // a CAF behind even after a clean shutdown. No-op when nothing is orphaned.
        // Wiring-order invariant: salvage MUST complete before the recorder/writer below
        // can exist — it transcodes every .caf under the root.
        let salvaged = await Task.detached { OrphanSalvager.salvage(store: store) }.value

        // The banner stays gated on the heartbeat (a crash), not on salvage results alone.
        if heartbeat.indicatesUncleanShutdown {
            recoveryNotice = salvaged.isEmpty
                ? "Listening stopped unexpectedly last session."
                : "Listening stopped unexpectedly — recovered \(salvaged.count) unfinished recording(s)."
            heartbeat.clear()
        }

        do {
            // CoreML load/compile can take hundreds of ms (seconds on a cold cache) —
            // off the MainActor so the loading indicator actually renders and animates.
            let detector = try await Task.detached(priority: .userInitiated) {
                try SileroSpeechDetector(modelURL: modelURL)
            }.value
            let recorder = RecorderStateMachine(
                detector: detector,
                writerFactory: CAFSegmentWriterFactory(store: store),
                store: store)
            let source = PhoneMicAudioSource()
            let newPipeline = ListeningPipeline(
                source: source, recorder: recorder, heartbeat: heartbeat,
                liveActivity: SottoLiveActivityController(),
                notifications: UserNotificationScheduler())
            pipeline = newPipeline

            let sessionObserver = AudioSessionObserver(backgroundTasks: UIKitBackgroundTasks())
            sessionObserver.onInterruptionBegan = { [weak newPipeline] in
                await newPipeline?.interrupt()
            }
            sessionObserver.onInterruptionEndedShouldResume = { [weak newPipeline] shouldResume in
                // Foregrounded + system says resume → restart. Backgrounded: engine.start()
                // fails (561145187); recovery stays with the intent/notification/app-open.
                guard shouldResume, UIApplication.shared.applicationState == .active else { return }
                await newPipeline?.resumeFromInterruption()
            }
            sessionObserver.onRouteChangeDeviceUnavailable = { [weak source] in
                try? await source?.rebuildTap()
            }
            sessionObserver.onMediaServicesReset = { [weak newPipeline] in
                // Full teardown + rebuild (SPEC): park, then restart the whole stack.
                await newPipeline?.interrupt()
                await newPipeline?.resumeFromInterruption()
            }
            sessionObserver.startObserving()
            observer = sessionObserver
        } catch {
            setupError = String(describing: error)
        }
    }
}

private struct PipelineView: View {
    let pipeline: ListeningPipeline
    let recoveryNotice: String?

    var body: some View {
        VStack(spacing: 24) {
            if let recoveryNotice {
                Text(recoveryNotice)
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .padding(.horizontal)
            }

            Text(statusLabel)
                .font(.largeTitle.bold())
                .foregroundStyle(statusColor)

            Text("Conversations: \(pipeline.finalizedCount)")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Button(buttonLabel) {
                Task {
                    switch pipeline.status {
                    case .idle: await pipeline.start()
                    case .interrupted: await pipeline.resumeFromInterruption()
                    default: await pipeline.stop()
                    }
                }
            }
            .buttonStyle(.borderedProminent)

            List(Array(pipeline.eventLog.enumerated().reversed()), id: \.offset) { _, line in
                Text(line)
                    .font(.footnote.monospaced())
            }
            .listStyle(.plain)
        }
        .padding(.top, 24)
    }

    private var buttonLabel: String {
        switch pipeline.status {
        case .idle: "Start Listening"
        case .interrupted: "Resume"
        default: "Stop"
        }
    }

    private var statusLabel: String {
        switch pipeline.status {
        case .idle: "Idle"
        case .starting: "Starting…"
        case .listening: "Listening"
        case .recording: "Recording"
        case .silence: "Silence"
        case .interrupted: "Paused — call"
        }
    }

    private var statusColor: Color {
        switch pipeline.status {
        case .idle: .secondary
        case .starting: .secondary
        case .listening: .green
        case .recording: .red
        case .silence: .orange
        case .interrupted: .orange
        }
    }
}

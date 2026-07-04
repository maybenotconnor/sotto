import SwiftUI

struct ContentView: View {
    @State private var pipeline: ListeningPipeline?
    @State private var setupError: String?
    @State private var recoveryNotice: String?

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
    }

    @MainActor
    private func setUp() async {
        guard pipeline == nil, setupError == nil else { return }
        guard let modelURL = Bundle.main.url(
            forResource: SileroSpeechDetector.modelResourceName,
            withExtension: "mlmodelc")
        else {
            setupError = "VAD model missing from app bundle"
            return
        }

        let store = SegmentStore()
        let heartbeat = HeartbeatStore()

        // Unclean-shutdown detection + salvage (SPEC "heartbeat/unclean-shutdown detection").
        if heartbeat.indicatesUncleanShutdown {
            let salvaged = await Task.detached { OrphanSalvager.salvage(store: store) }.value
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
            pipeline = ListeningPipeline(
                source: PhoneMicAudioSource(), recorder: recorder, heartbeat: heartbeat)
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

            Button(pipeline.status == .idle ? "Start Listening" : "Stop") {
                Task {
                    if pipeline.status == .idle {
                        await pipeline.start()
                    } else {
                        await pipeline.stop()
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

    private var statusLabel: String {
        switch pipeline.status {
        case .idle: "Idle"
        case .starting: "Starting…"
        case .listening: "Listening"
        case .recording: "Recording"
        case .silence: "Silence"
        }
    }

    private var statusColor: Color {
        switch pipeline.status {
        case .idle: .secondary
        case .starting: .secondary
        case .listening: .green
        case .recording: .red
        case .silence: .orange
        }
    }
}

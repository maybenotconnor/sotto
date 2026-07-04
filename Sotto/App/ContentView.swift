import SwiftUI

struct ContentView: View {
    @State private var pipeline: ListeningPipeline?
    @State private var setupError: String?

    var body: some View {
        NavigationStack {
            Group {
                if let setupError {
                    ContentUnavailableView(
                        "Setup failed",
                        systemImage: "exclamationmark.triangle",
                        description: Text(setupError))
                } else if let pipeline {
                    PipelineView(pipeline: pipeline)
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
        do {
            // CoreML load/compile can take hundreds of ms (seconds on a cold cache) —
            // off the MainActor so the loading indicator actually renders and animates.
            let detector = try await Task.detached(priority: .userInitiated) {
                try SileroSpeechDetector(modelURL: modelURL)
            }.value
            pipeline = ListeningPipeline(source: PhoneMicAudioSource(), detector: detector)
        } catch {
            setupError = String(describing: error)
        }
    }
}

private struct PipelineView: View {
    let pipeline: ListeningPipeline

    var body: some View {
        VStack(spacing: 24) {
            Text(statusLabel)
                .font(.largeTitle.bold())
                .foregroundStyle(statusColor)

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
        case .speechActive: "Speech"
        }
    }

    private var statusColor: Color {
        switch pipeline.status {
        case .idle: .secondary
        case .starting: .secondary
        case .listening: .green
        case .speechActive: .orange
        }
    }
}

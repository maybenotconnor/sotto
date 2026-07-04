import SwiftUI
import UIKit

struct ContentView: View {
    let model: AppModel

    var body: some View {
        NavigationStack {
            Group {
                if let setupError = model.setupError {
                    ContentUnavailableView(
                        "Setup failed",
                        systemImage: "exclamationmark.triangle",
                        description: Text(setupError))
                } else if let pipeline = model.pipeline {
                    PipelineView(pipeline: pipeline, recoveryNotice: model.recoveryNotice)
                } else {
                    ProgressView("Loading VAD model…")
                }
            }
            .navigationTitle("Sotto")
        }
        .task { await model.ensureSetUp() }
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
        case .interrupted: pipeline.haltReason == .userPause ? "Paused by you" : "Paused — call"
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

import SwiftUI
import UIKit

/// SPEC "Detail view": read one conversation; verify against audio.
struct ConversationDetailView: View {
    let model: AppModel
    let entry: DaySegmentEntry
    let dayDirectory: URL

    @State private var transcript: TranscriptFile?
    @State private var player = AudioPlayerController()
    @State private var audioExists = false
    @State private var confirmDelete = false
    @Environment(\.dismiss) private var dismiss

    private var m4aURL: URL { dayDirectory.appendingPathComponent("\(entry.id).m4a") }
    private var mdURL: URL { dayDirectory.appendingPathComponent("\(entry.id).md") }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                metadataRow
                if audioExists { playerControls }
                transcriptBody
            }
            .padding()
        }
        .navigationTitle(entry.title ?? entry.startTime.formatted(.dateTime.hour().minute()))
        .toolbar { toolbarContent }
        .task {
            transcript = TranscriptFile.parse(url: mdURL)
            // hasAudio is advisory (M5 review): stat the file before offering playback.
            audioExists = FileManager.default.fileExists(atPath: m4aURL.path)
            if audioExists { player.load(url: m4aURL) }
        }
        .onDisappear { player.stop() }
        .confirmationDialog("Delete this conversation?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                Task {
                    await model.deleteSegment(m4aURL: m4aURL)
                    dismiss()
                }
            }
        }
    }

    private var metadataRow: some View {
        HStack(spacing: 12) {
            Label(entry.backend == "deepgram" ? "Deepgram" : "On-device",
                  systemImage: entry.backend == "deepgram" ? "cloud" : "iphone")
            if let words = entry.wordCount { Text("\(words) words") }
            Text("\(Int(entry.duration / 60)) min")
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }

    private var playerControls: some View {
        VStack(spacing: 8) {
            Slider(
                value: .init(get: { player.currentTime }, set: { player.seek(to: $0) }),
                in: 0...max(player.duration, 1))
            HStack(spacing: 24) {
                Button { player.skip(-15) } label: { Image(systemName: "gobackward.15") }
                Button { player.togglePlay() } label: {
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.largeTitle)
                }
                Button { player.skip(15) } label: { Image(systemName: "goforward.15") }
                Menu("\(player.rate, format: .number)×") {
                    ForEach([Float(1.0), 1.5, 2.0], id: \.self) { rate in
                        Button("\(rate, format: .number)×") { player.rate = rate }
                    }
                }
                .font(.footnote)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var transcriptBody: some View {
        switch entry.transcriptionState {
        case "queued":
            HStack(spacing: 8) { ProgressView(); Text("Transcribing…") }
                .foregroundStyle(.secondary)
        case "failed":
            VStack(alignment: .leading, spacing: 8) {
                Text("Transcription failed.").foregroundStyle(.red)
                Button("Retry") { Task { await model.retryTranscription(m4aURL: m4aURL) } }
            }
        default:
            if let transcript {
                VStack(alignment: .leading, spacing: 16) {
                    if let summary = transcript.summary {
                        GroupBox("Summary") {
                            Text(summary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    // Deepgram speaker turns arrive as markdown bold; render as styled text.
                    // `transcriptBody` (never the raw `body`) so the `## Summary`/`## Transcript`
                    // section markers (M8 meeting notes) never appear as literal text.
                    Text(LocalizedStringKey(transcript.transcriptBody))
                        .textSelection(.enabled)
                }
            } else {
                Text("Transcript unavailable.").foregroundStyle(.secondary)
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            ShareLink(item: mdURL) { Image(systemName: "square.and.arrow.up") }
            Menu {
                Button("Copy text") {
                    UIPasteboard.general.string = transcript?.body ?? ""
                }
                if audioExists {
                    Button("Re-transcribe with current backend") {
                        Task { await model.retranscribe(m4aURL: m4aURL) }
                    }
                }
                Button("Delete", role: .destructive) { confirmDelete = true }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }
}

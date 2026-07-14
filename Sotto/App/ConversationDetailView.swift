import SwiftUI
import UIKit

/// SPEC "Detail view": read one conversation; verify against audio.
struct ConversationDetailView: View {
    let model: AppModel
    let entry: DaySegmentEntry
    let dayDirectory: URL

    @State private var transcript: TranscriptFile?
    // The transcript body pre-split into render blocks (see `TranscriptFile.transcriptBlocks`).
    // Computed once in `.task` — not inline in `body` — so an unrelated re-render (e.g. the
    // player slider ticking) never re-splits the whole document.
    @State private var blocks: [TranscriptFile.TranscriptBlock] = []
    @State private var player = AudioPlayerController()
    @State private var audioExists = false
    @State private var confirmDelete = false
    // Rename (2026-07-07 spec): the editable hero-title binding + last-persisted value.
    // `savedTitle` is what commit no-ops and reverts compare against — it starts as the same
    // title-or-time fallback the title field first displays.
    @State private var editableTitle = ""
    @State private var savedTitle = ""
    /// Drives the title field's keyboard: set false to end editing (Return, the keyboard "Done"
    /// button, and interactive scroll all clear it).
    @FocusState private var titleEditing: Bool
    @Environment(\.dismiss) private var dismiss

    private var m4aURL: URL { dayDirectory.appendingPathComponent("\(entry.id).m4a") }
    private var mdURL: URL { dayDirectory.appendingPathComponent("\(entry.id).md") }

    var body: some View {
        // The title is shown and edited in one place — the hero TextField in `mainContent`
        // (there is no nav-bar title), so the transcript-present/absent branches that only
        // differed by their navigation title collapse into a single content view.
        mainContent
            .task {
                let parsed = TranscriptFile.parse(url: mdURL)
                transcript = parsed
                // Split into blocks up front (cheap string work) so the render path only ever
                // markdown-parses the handful of blocks the LazyVStack materializes on screen.
                blocks = parsed?.transcriptBlocks ?? []
                savedTitle = entry.title ?? entry.startTime.formatted(.dateTime.hour().minute())
                editableTitle = savedTitle
                // hasAudio is advisory (M5 review): stat the file before offering playback.
                audioExists = FileManager.default.fileExists(atPath: m4aURL.path)
                if audioExists { player.load(url: m4aURL) }
            }
            // Titles are single-line, so a newline means the user pressed Return in the wrapping
            // field: strip the newline(s) and end editing. We deliberately do NOT commit here —
            // committing on every keystroke reverts a transiently-empty field (you could never
            // delete the last character) and rewrites the file per key. The commit happens once,
            // when editing ends, in the `titleEditing` handler below.
            .onChange(of: editableTitle) { _, newValue in
                guard newValue.contains(where: \.isNewline) else { return }
                // Join across newlines with a space so a pasted multi-line string stays readable
                // ("line1 line2"), not concatenated; a lone trailing Return just yields the text back.
                let cleaned = newValue.split(whereSeparator: \.isNewline).joined(separator: " ")
                editableTitle = cleaned
                titleEditing = false
            }
            // Commit when editing ends (Return, the "Done" button, and interactive scroll all clear
            // the focus). An empty field is a legitimate state *while* typing; only now do we
            // enforce the non-empty rule — a blank title reverts to the last saved value.
            .onChange(of: titleEditing) { _, editing in
                if !editing { commitRename(editableTitle) }
            }
            // Safety net: if the view is dismissed while the keyboard is still up (swipe-back
            // mid-edit), persist the final value. `commitRename` no-ops when it is unchanged.
            .onDisappear {
                commitRename(editableTitle)
                player.stop()
            }
            .alert("Delete this conversation?", isPresented: $confirmDelete) {
                Button("Delete", role: .destructive) {
                    Task {
                        await model.deleteSegment(m4aURL: m4aURL)
                        dismiss()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Deletes the audio and transcript permanently.")
            }
    }

    private var mainContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // The one and only title surface: an editable, wrapping hero title. Long
                // auto-generated titles wrap and stay fully visible, and tapping it renames the
                // conversation (there is no nav-bar title). It stays multi-line for *layout* only
                // — newlines are neutralized in the body's `.onChange`, so a saved title is always
                // one line. Binds to `editableTitle` (seeded in `.task`); commits via `commitRename`.
                TextField("Title", text: $editableTitle, axis: .vertical)
                    .font(.title2.weight(.semibold))
                    .focused($titleEditing)
                metadataRow
                if audioExists { playerControls }
                transcriptBody
            }
            .padding()
        }
        .scrollDismissesKeyboard(.interactively)
        .toolbar { toolbarContent }
    }

    /// Commit rule (spec): called once when editing ends. Persist only a non-empty value that
    /// differs from the last saved one; an unchanged value no-ops and a value that trims/
    /// sanitizes to empty reverts the field to `savedTitle` — this also keeps the time
    /// placeholder from being persisted as a literal title.
    private func commitRename(_ newValue: String) {
        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != savedTitle else { return }
        let sanitized = TranscriptMarkdownWriter.sanitizeInline(trimmed)
        guard !sanitized.isEmpty else {
            editableTitle = savedTitle
            return
        }
        savedTitle = sanitized
        editableTitle = sanitized   // reflect sanitization; re-entry no-ops via the guard
        Task {
            await model.renameSegment(
                m4aURL: m4aURL, title: sanitized, startTime: entry.startTime)
        }
    }

    private var metadataRow: some View {
        HStack(spacing: 12) {
            Label(entry.backend == "deepgram" ? "Deepgram" : "On-device",
                  systemImage: entry.backend == "deepgram" ? "cloud" : "iphone")
            if let words = entry.wordCount { Text("\(words) words") }
            Text("\(Int(entry.duration / 60)) min")
            // M12 Task 12: nil means phone mic (pre-M12 files and phone-mic-only entries
            // alike) — no chip in that case, only shown when a non-default source is known.
            if let source = entry.source {
                Label(AudioSourceType(rawValue: source)?.displayName ?? source, systemImage: "waveform")
            }
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
                Button {
                    let pipeline = model.pipeline
                    player.togglePlay(
                        phoneMicCapturing: pipeline?.activeSourceType == .phoneMic,
                        pipelineActive: pipeline.map { $0.status != .idle } ?? false)
                } label: {
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
                // Native whole-block copy for the read-only transcript. On iOS `.textSelection`
                // enables long-press → Copy of an entire `Text` (iOS has no in-place range
                // selection — that is macOS-only); applied to the container so both the Summary
                // and the body are copyable. Interactive controls (player, title field) are
                // unaffected — the modifier only touches `Text`/`Label`.
                VStack(alignment: .leading, spacing: 16) {
                    if let summary = transcript.summary {
                        GroupBox("Summary") {
                            Text(summary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    // One `Text` per block inside a `LazyVStack`, not a single `Text` over the
                    // whole body: rendering the entire document as one `Text` exceeds CoreText's
                    // layout ceiling (it reports a size but draws blank) and forces a synchronous
                    // full-document markdown parse on open. The LazyVStack builds and parses only
                    // the blocks near the viewport, so open is instant and no block can blank out.
                    // Blocks derive from `transcriptBody` (never the raw `body`) so the `## Summary`
                    // / `## Transcript` markers (M8 meeting notes) never appear as literal text.
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(blocks) { block in
                            Text(TranscriptFile.attributed(block.text))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .textSelection(.enabled)
            } else {
                Text("Transcript unavailable.").foregroundStyle(.secondary)
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // Single trailing slot: a "Done" button while the title field is focused (ends editing /
        // dismisses the keyboard), otherwise the ellipsis actions menu. The Done affordance lives
        // in the nav bar rather than a `.keyboard`-placement toolbar because iOS 26 renders those
        // as an ugly detached floating bar. Return and interactive scroll also end editing.
        // (Keep this a SINGLE trailing item — historically a second one collapsed into iOS's own
        // "•••" overflow, revealing our ellipsis behind a second tap.)
        ToolbarItem(placement: .topBarTrailing) {
            if titleEditing {
                Button("Done") { titleEditing = false }
            } else {
                Menu {
                    ShareLink(item: mdURL) { Label("Share", systemImage: "square.and.arrow.up") }
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
}

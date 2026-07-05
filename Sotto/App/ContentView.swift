import AVFAudio
import SwiftUI
import UIKit

/// M9 unified home screen: one glance = current state; one tap = start/stop; scroll down for
/// history (SPEC "UI specification" note, superseding the old Main + List screens).
struct ContentView: View {
    let model: AppModel
    @State private var micDenied = false
    // SettingsStore/UserDefaults isn't Observable, so first-run state is mirrored into this
    // @State on appearance (`.task` below) and flipped by OnboardingView's completion closure
    // — the mirror is what actually drives the view swap; the underlying setting is the
    // source of truth for the NEXT launch.
    @State private var showOnboarding = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if showOnboarding {
                OnboardingView(model: model) {
                    model.settings.hasCompletedOnboarding = true
                    showOnboarding = false
                }
            } else {
                NavigationStack {
                    Group {
                        if let setupError = model.setupError {
                            ContentUnavailableView(
                                "Setup failed",
                                systemImage: "exclamationmark.triangle",
                                description: Text(setupError))
                        } else if let pipeline = model.pipeline {
                            HomeScreen(model: model, pipeline: pipeline, micDenied: micDenied)
                        } else {
                            ProgressView("Preparing…")
                        }
                    }
                    .navigationTitle("Sotto")
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            NavigationLink {
                                SettingsView(model: model)
                            } label: {
                                Image(systemName: "gear")
                            }
                        }
                    }
                }
            }
        }
        .task {
            showOnboarding = !model.settings.hasCompletedOnboarding
            await model.ensureSetUp()
            micDenied = AVAudioApplication.shared.recordPermission == .denied
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            micDenied = AVAudioApplication.shared.recordPermission == .denied
            Task { await model.refreshLoadedHistory() }
            // SPEC: leftovers drain on next resume/foreground — also releases jobs that were
            // gated on Wi-Fi-only uploads while the user was away from home.
            Task { await model.queue?.drain() }
        }
    }
}

/// M9 unified home: compact status card + full-weight banners (scrolling away with the
/// list — the always-visible recording indication is carried by the system orange mic dot
/// and the Live Activity, not by this header), a live "Recording…" row while a segment is
/// open, then infinite-scroll history with sticky day headers, newest first.
private struct HomeScreen: View {
    let model: AppModel
    let pipeline: ListeningPipeline
    let micDenied: Bool

    /// Delete-confirmation state: a plain `(DaySegmentEntry, AppModel.HistorySection)?`
    /// tuple works for the dialog's `isPresented` `!= nil` check, but a small struct reads
    /// better at the two use sites below (`pendingDelete.entry` / `.section` instead of
    /// `.0` / `.1`) — implementer's choice per the task brief.
    private struct PendingDelete {
        let entry: DaySegmentEntry
        let section: AppModel.HistorySection
    }
    @State private var pendingDelete: PendingDelete?

    var body: some View {
        List {
            // Header section — scrolls away with the list (user decision; the system orange
            // mic dot + Live Activity carry the always-visible recording indication).
            Section {
                statusCard
                banners   // moved from the old MainScreen at FULL weight: same copy, same
                          // action buttons (Download model / Try again / Open Settings /
                          // Dismiss), stacked when several apply (user decision: don't
                          // over-compress).
            }
            .listRowSeparator(.hidden)

            if let started = pipeline.currentSegmentStartDate {
                Section { LiveRecordingRow(startedAt: started) }
            }

            ForEach(model.historySections) { section in
                Section(header: Text(dayTitle(for: section))) {
                    ForEach(HomeRow.rows(for: section.index)) { row in
                        rowView(row, in: section)
                    }
                }
            }

            if model.hasMoreHistory {
                Section {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .onAppear { Task { await model.loadMoreHistory() } }
                }
                .listRowSeparator(.hidden)
            } else if model.historySections.isEmpty && model.hasLoadedHistoryOnce {
                Section {
                    Text(pipeline.status != .idle
                        ? "Nothing recorded yet — Sotto is listening."
                        : "Start listening to capture your first conversation.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .refreshable { await model.loadInitialHistory() }
        .task { await model.loadInitialHistory() }
        .task(id: pipeline.finalizedCount) { await model.refreshLoadedHistory() }
        .confirmationDialog(
            "Delete this conversation?", isPresented: .init(
                get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
        ) {
            Button("Delete", role: .destructive) {
                if let pendingDelete {
                    Task {
                        // deleteSegment already refreshes loaded history internally.
                        await model.deleteSegment(
                            m4aURL: pendingDelete.section.dayDirectory
                                .appendingPathComponent("\(pendingDelete.entry.id).m4a"))
                    }
                }
            }
        } message: {
            Text("Deletes the audio and transcript permanently.")
        }
    }

    private var statusCard: some View {
        HStack(spacing: 12) {
            Circle().fill(statusColor).frame(width: 12, height: 12)
            VStack(alignment: .leading, spacing: 1) {
                Text(statusLabel).font(.headline)
                if pipeline.status != .idle, let started = pipeline.sessionStartedAt {
                    Text(started, style: .timer)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
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
            .tint(pipeline.status == .idle ? .accentColor : .red)
            .disabled(micDenied && (pipeline.status == .idle || pipeline.status == .interrupted))
        }
        .padding(.vertical, 4)
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
        } else if case .unsupported = model.assetState {
            NoticeBanner(
                text: "On-device transcription isn't available on this device (Simulator or non-Apple-Intelligence hardware). Recordings are saved; transcripts need a supported iPhone or a Deepgram key in Settings.",
                color: .secondary)
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
        case .silence: "Listening"
        case .interrupted: pipeline.haltReason == .userPause ? "Paused by you" : "Paused — call"
        }
    }

    private var statusColor: Color {
        switch pipeline.status {
        case .idle: .secondary
        case .starting: .secondary
        case .listening, .silence: .green
        case .recording: .red
        case .interrupted: .orange
        }
    }

    private func dayTitle(for section: AppModel.HistorySection) -> String {
        if Calendar.current.isDateInToday(section.date) { return "Today" }
        if Calendar.current.isDateInYesterday(section.date) { return "Yesterday" }
        return section.date.formatted(.dateTime.month(.wide).day())
    }

    @ViewBuilder
    private func rowView(_ row: HomeRow, in section: AppModel.HistorySection) -> some View {
        switch row {
        case .gap(_, let gap):
            GapRowView(gap: gap)
        case .segment(let entry):
            NavigationLink {
                ConversationDetailView(
                    model: model, entry: entry, dayDirectory: section.dayDirectory)
            } label: {
                SegmentRowView(entry: entry, dayDirectory: section.dayDirectory, model: model)
            }
            .swipeActions(edge: .trailing) {
                Button(role: .destructive) { pendingDelete = PendingDelete(entry: entry, section: section) } label: {
                    Label("Delete", systemImage: "trash")
                }
                ShareLink(item: section.dayDirectory.appendingPathComponent("\(entry.id).md")) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            }
        }
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

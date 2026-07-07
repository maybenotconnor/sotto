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

/// M9 unified home: a single morphing status header — one status card that also carries the
/// "Recording…" state and segment timer while a segment is open, so there is never a second
/// header-like row below it (user-reported: a separate live row duplicated the header) —
/// plus full-weight banners (scrolling away with the list — the always-visible recording
/// indication is carried by the system orange mic dot and the Live Activity, not by this
/// header), then infinite-scroll history with sticky day headers, newest first.
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

    /// Merge-conversations selection mode. Keys are "<sectionID>/<entryID>" (entry ids
    /// repeat across days). Plain edit-mode List selection; rows outside history
    /// segments opt out via .selectionDisabled.
    @State private var editMode: EditMode = .inactive
    @State private var selectedKeys = Set<String>()
    @State private var confirmingMerge = false
    @State private var mergeFailed = false
    /// True while a confirmed merge is in flight (file stitching can take seconds) — gates
    /// the Merge bar's button so a second tap can't fire a duplicate merge (which would fail
    /// with a false "Couldn't merge" alert since the originals are already gone) and drives
    /// the bar's progress indicator.
    @State private var merging = false

    private var eligibility: AppModel.MergeEligibility {
        AppModel.mergeEligibility(selectedKeys: selectedKeys, sections: model.historySections)
    }

    /// Merge bar/dialog count: prefer the eligible entry count (accurate — matches what will
    /// actually be merged) over raw `selectedKeys.count`, which can include ineligible/stale
    /// selections. Falls back to `selectedKeys.count` when not eligible; the Merge button is
    /// disabled in that case anyway, so the fallback value is never actionable.
    private var mergeCount: Int {
        if case .eligible(_, let entries) = eligibility { return entries.count }
        return selectedKeys.count
    }

    /// `model.settings` is UserDefaults-backed, not @Observable — a plain read in `banners`
    /// would go stale when Settings changes the engine. @AppStorage observes the same
    /// defaults key; nil (pre-M10 installs) falls back to the store's migrating getter.
    @AppStorage("transcriptionEngine") private var engineRaw: String?
    private var onDeviceEngineSelected: Bool {
        let engine = engineRaw.flatMap(TranscriptionBackend.init(rawValue:))
            ?? model.settings.transcriptionEngine
        return engine == .speechAnalyzer
    }

    var body: some View {
        List(selection: $selectedKeys) {
            // Header section — scrolls away with the list (user decision; the system orange
            // mic dot + Live Activity carry the always-visible recording indication).
            Section {
                statusCard
                    .selectionDisabled(true)
                banners   // moved from the old MainScreen at FULL weight: same copy, same
                          // action buttons (Download model / Try again / Open Settings /
                          // Dismiss), stacked when several apply (user decision: don't
                          // over-compress).
                    .selectionDisabled(true)
            }
            .listRowSeparator(.hidden)

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
                        .selectionDisabled(true)
                }
                .listRowSeparator(.hidden)
            } else if model.historySections.isEmpty && model.hasLoadedHistoryOnce {
                Section {
                    Text(emptyStateText)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .selectionDisabled(true)
                }
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .environment(\.editMode, $editMode)
        .refreshable { await model.loadInitialHistory() }
        .task { await model.loadInitialHistory() }
        .task(id: pipeline.finalizedCount) { await model.refreshLoadedHistory() }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if !model.historySections.isEmpty {
                    Button(editMode == .active ? "Done" : "Select") {
                        withAnimation {
                            editMode = editMode == .active ? .inactive : .active
                            selectedKeys.removeAll()
                        }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if editMode == .active {
                VStack(spacing: 6) {
                    Button {
                        confirmingMerge = true
                    } label: {
                        if merging {
                            ProgressView()
                        } else {
                            Text("Merge \(mergeCount) conversations")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(merging || { if case .eligible = eligibility { false } else { true } }())
                    if let hint = eligibilityHint {
                        Text(hint)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity)
                .background(.bar)
            }
        }
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
        .confirmationDialog(
            "Merge \(mergeCount) conversations into one?",
            isPresented: $confirmingMerge
        ) {
            Button("Merge", role: .destructive) {
                guard case .eligible(let dayDirectory, let entries) = eligibility else { return }
                merging = true
                Task {
                    if await model.mergeSegments(dayDirectory: dayDirectory, entries: entries) {
                        withAnimation {
                            editMode = .inactive
                            selectedKeys.removeAll()
                        }
                        merging = false
                    } else {
                        mergeFailed = true
                        merging = false
                    }
                }
            }
        } message: {
            Text("The originals are replaced. This can't be undone.")
        }
        .alert("Couldn't merge", isPresented: $mergeFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Merging the audio failed. Nothing was changed.")
        }
    }

    private var eligibilityHint: String? {
        switch eligibility {
        case .eligible: nil
        case .tooFew:
            selectedKeys.isEmpty
                ? "Select conversations to merge"
                : "Select at least two conversations"
        case .multipleDays: "Select conversations from the same day"
        case .notAllDone: "Wait for transcription to finish"
        }
    }

    private var statusCard: some View {
        HStack(spacing: 12) {
            if case .segmentOpen = headerState {
                // Reuses the old LiveRecordingRow's pulse treatment — now it lives on the
                // header itself instead of on a second, separate row underneath it.
                PulsingDot(color: .red)
            } else {
                Circle().fill(headerState.dotColor).frame(width: 12, height: 12)
            }
            VStack(alignment: .leading, spacing: 1) {
                // M12 Task 12: source suffix only when an Omi is paired — phone-mic-only
                // users see the exact same label as before (SPEC "UI & surfacing").
                if let source = pipeline.activeSourceType, model.pairedOmiName != nil {
                    Text("\(headerState.label) · \(source.displayName)").font(.headline)
                } else {
                    Text(headerState.label).font(.headline)
                }
                if let timerStart = headerState.timerStart {
                    Text(timerStart, style: .timer)
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
                    // Routed through AppModel (not a direct pipeline.stop()) so a pair/forget
                    // that happened mid-session gets its deferred rebuild the moment this
                    // session actually ends (M12 final review Important #2).
                    default: await model.stopListening()
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
        } else if case .unsupported = model.assetState, onDeviceEngineSelected {
            NoticeBanner(
                text: "This device doesn't support on-device transcription. Select another transcription engine in Settings.",
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
        // M12 Task 12: same visual weight as micDenied above — full text + action button,
        // stacked. Only for paired users (SPEC "UI & surfacing"); capture continues on the
        // phone mic regardless, so this is informational, not blocking.
        if let reason = AppModel.bluetoothBannerReason(
            pairedOmiName: model.pairedOmiName, connectionState: model.omiConnectionState) {
            VStack(spacing: 6) {
                NoticeBanner(
                    text: reason == .poweredOff
                        ? "Bluetooth is off — your Omi can't connect. Recording uses the iPhone mic."
                        : "Sotto needs Bluetooth permission to use your Omi. Recording uses the iPhone mic.",
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

    /// The single header's state machine: one segment-open case takes priority over the raw
    /// pipeline status so the header morphs into the old live row's "Recording…" + segment
    /// timer instead of showing both a status card AND a separate live row (user-reported:
    /// "you build a second header").
    private enum HeaderState {
        case idle
        case starting
        case interrupted(ListeningPipeline.HaltReason?)
        case listening(sessionStart: Date?)
        case segmentOpen(start: Date)

        var label: String {
            switch self {
            case .idle: "Idle"
            case .starting: "Starting…"
            case .interrupted(let reason): reason == .userPause ? "Paused by you" : "Paused — call"
            case .listening: "Listening"
            case .segmentOpen: "Recording…"
            }
        }

        var dotColor: Color {
            switch self {
            case .idle, .starting: .secondary
            case .interrupted: .orange
            case .listening: .green
            case .segmentOpen: .red
            }
        }

        /// One timer at a time: the segment timer while a segment is open, else the session
        /// timer while listening/silence, else none.
        var timerStart: Date? {
            switch self {
            case .segmentOpen(let start): start
            case .listening(let sessionStart): sessionStart
            case .idle, .starting, .interrupted: nil
            }
        }
    }

    private var headerState: HeaderState {
        if let started = pipeline.currentSegmentStartDate {
            return .segmentOpen(start: started)
        }
        switch pipeline.status {
        case .idle: return .idle
        case .starting: return .starting
        case .interrupted: return .interrupted(pipeline.haltReason)
        case .listening, .recording, .silence: return .listening(sessionStart: pipeline.sessionStartedAt)
        }
    }

    private var emptyStateText: String {
        if pipeline.currentSegmentStartDate != nil {
            return "Recording your first conversation…"
        }
        return pipeline.status != .idle
            ? "Nothing recorded yet — Sotto is listening."
            : "Start listening to capture your first conversation."
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
                .selectionDisabled(true)
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
            .tag("\(section.id)/\(entry.id)")
        }
    }
}

/// Pulsing dot for the header's segment-open state — the same pulse treatment the old
/// standalone `LiveRecordingRow` used, now folded into the single status header.
private struct PulsingDot: View {
    let color: Color
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 12, height: 12)
            .opacity(pulsing ? 0.35 : 1.0)
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulsing)
            .onAppear { pulsing = true }
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

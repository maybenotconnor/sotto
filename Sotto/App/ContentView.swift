import AVFAudio
import SwiftUI

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

/// M9 unified home, reskinned 2026-07-10 (home-header-refresh spec): a single Porcelain
/// HeroCard carries state + timer + action (and, after the banner fold-in, all notices),
/// then infinite-scroll history with sticky day headers, newest first. The card scrolls
/// away with the list — the system orange mic dot and the Live Activity carry the
/// always-visible recording indication.
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

    var body: some View {
        List(selection: $selectedKeys) {
            // Header section — scrolls away with the list (user decision; the system orange
            // mic dot + Live Activity carry the always-visible recording indication).
            Section {
                HeroCard(model: model, pipeline: pipeline, micDenied: micDenied)
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
                    VStack(spacing: 14) {
                        WaveMark()
                            .stroke(
                                Color("Ink").opacity(0.55),
                                style: StrokeStyle(lineWidth: 5, lineCap: .round))
                            .frame(width: 150, height: 30)
                        Text(emptyStateText)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 24)
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

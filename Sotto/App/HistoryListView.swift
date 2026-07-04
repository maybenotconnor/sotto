import SwiftUI

/// SPEC "List view": browse a day's conversations from _day.json.
struct HistoryListView: View {
    let model: AppModel
    @State private var day = Date()
    @State private var index: DayIndex?
    @State private var pendingDelete: DaySegmentEntry?

    private var dayDirectory: URL { model.dayDirectory(for: day) }

    var body: some View {
        List {
            if let index {
                if index.segments.isEmpty && index.gaps.isEmpty {
                    emptyRow
                } else {
                    ForEach(rows(for: index), id: \.id) { row in
                        rowView(row)
                    }
                }
            } else {
                emptyRow
            }
        }
        .navigationTitle(dayTitle)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { shift(by: -1) } label: { Image(systemName: "chevron.left") }
                Button { shift(by: 1) } label: { Image(systemName: "chevron.right") }
                    .disabled(Calendar.current.isDateInToday(day))
            }
        }
        .task(id: day) { await reload() }
        .refreshable { await reload() }
        .confirmationDialog(
            "Delete this conversation?", isPresented: .init(
                get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
        ) {
            Button("Delete", role: .destructive) {
                if let entry = pendingDelete {
                    Task {
                        await model.deleteSegment(m4aURL: dayDirectory.appendingPathComponent("\(entry.id).m4a"))
                        await reload()
                    }
                }
            }
        } message: {
            Text("Deletes the audio and transcript permanently.")
        }
    }

    // Interleave gap markers between rows by time (SPEC).
    private enum Row: Identifiable {
        case segment(DaySegmentEntry)
        case gap(DayGapEntry)
        var id: String {
            switch self {
            case .segment(let entry): "s-\(entry.id)"
            case .gap(let gap): "g-\(gap.from.timeIntervalSinceReferenceDate)"
            }
        }
        var sortDate: Date {
            switch self {
            case .segment(let entry): entry.startTime
            case .gap(let gap): gap.from
            }
        }
    }

    private func rows(for index: DayIndex) -> [Row] {
        (index.segments.map(Row.segment) + index.gaps.map(Row.gap))
            .sorted { $0.sortDate < $1.sortDate }
    }

    @ViewBuilder
    private func rowView(_ row: Row) -> some View {
        switch row {
        case .gap(let gap):
            Label {
                Text("Listening stopped unexpectedly at \(gap.from, format: .dateTime.hour().minute())")
                    .font(.footnote)
            } icon: {
                Image(systemName: "exclamationmark.triangle")
            }
            .foregroundStyle(.orange)
        case .segment(let entry):
            NavigationLink {
                ConversationDetailView(model: model, entry: entry, dayDirectory: dayDirectory)
            } label: {
                SegmentRowView(entry: entry, dayDirectory: dayDirectory, model: model)
            }
            .swipeActions(edge: .trailing) {
                Button(role: .destructive) { pendingDelete = entry } label: {
                    Label("Delete", systemImage: "trash")
                }
                ShareLink(item: dayDirectory.appendingPathComponent("\(entry.id).md")) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            }
        }
    }

    private var emptyRow: some View {
        Text(model.pipeline?.status != .idle && Calendar.current.isDateInToday(day)
            ? "Nothing recorded yet — Sotto is listening."
            : "Start listening to capture your first conversation.")
            .foregroundStyle(.secondary)
    }

    private var dayTitle: String {
        Calendar.current.isDateInToday(day) ? "Today"
            : day.formatted(.dateTime.month().day())
    }

    private func shift(by days: Int) {
        day = Calendar.current.date(byAdding: .day, value: days, to: day) ?? day
    }

    private func reload() async {
        index = await model.loadDayIndex(for: day)
    }
}

struct SegmentRowView: View {
    let entry: DaySegmentEntry
    let dayDirectory: URL
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(entry.startTime, format: .dateTime.hour().minute())
                    .font(.headline)
                Text("· \(Int(entry.duration / 60)) min")
                    .foregroundStyle(.secondary)
                Spacer()
                Image(systemName: entry.backend == "deepgram" ? "cloud" : "iphone")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
            switch entry.transcriptionState {
            case "queued":
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Transcribing…").font(.footnote).foregroundStyle(.secondary)
                }
            case "failed":
                Button {
                    Task {
                        await model.retryTranscription(
                            m4aURL: dayDirectory.appendingPathComponent("\(entry.id).m4a"))
                    }
                } label: {
                    Label("Transcription failed — retry", systemImage: "arrow.clockwise")
                        .font(.footnote)
                }
                .buttonStyle(.borderless)
            default:
                if let preview = TranscriptFile.parse(
                    url: dayDirectory.appendingPathComponent("\(entry.id).md"))?.previewText {
                    Text(preview).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                }
                if let words = entry.wordCount {
                    Text("\(words) words").font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

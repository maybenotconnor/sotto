import SwiftUI

/// One day's rows: segments + gap markers interleaved, NEWEST FIRST (user decision).
enum HomeRow: Identifiable {
    case segment(dayID: String, DaySegmentEntry)
    case gap(dayID: String, index: Int, DayGapEntry)

    // Identity must be unique across the whole flattened List, not just within one day. Entry
    // ids are HH-mm-ss basenames that repeat across day folders, so the day id is part of the
    // identity — matching the day-namespaced List selection tag in ContentView. Without it, two
    // same-wall-clock-time conversations on different days shared one ForEach identity and
    // SwiftUI bound transient row state (the gray press/selection highlight) to the wrong row.
    var id: String {
        switch self {
        case .segment(let dayID, let entry): "\(dayID)/s-\(entry.id)"
        case .gap(let dayID, let index, let gap):
            "\(dayID)/g-\(index)-\(gap.from.timeIntervalSinceReferenceDate)"
        }
    }

    var sortDate: Date {
        switch self {
        case .segment(_, let entry): entry.startTime
        case .gap(_, _, let gap): gap.from
        }
    }

    static func rows(for index: DayIndex, dayID: String) -> [HomeRow] {
        (index.segments.map { HomeRow.segment(dayID: dayID, $0) }
            + index.gaps.enumerated().map { HomeRow.gap(dayID: dayID, index: $0.offset, $0.element) })
            .sorted { $0.sortDate > $1.sortDate }   // newest first
    }
}

struct GapRowView: View {
    let gap: DayGapEntry

    var body: some View {
        Label {
            Text("Listening stopped unexpectedly at \(gap.from, format: .dateTime.hour().minute())")
                .font(.footnote)
        } icon: {
            Image(systemName: "exclamationmark.triangle")
        }
        .foregroundStyle(.orange)
    }
}

struct SegmentRowView: View {
    let entry: DaySegmentEntry
    let dayDirectory: URL
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let title = entry.title {
                HStack {
                    Text(title)
                        .font(.headline)
                        .lineLimit(2)
                    Spacer()
                    Image(systemName: entry.backend == "deepgram" ? "cloud" : "iphone")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
                Text("\(entry.startTime, format: .dateTime.hour().minute()) · \(Int(entry.duration / 60)) min")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
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
                if let preview = PreviewCache.shared.preview(
                    for: dayDirectory.appendingPathComponent("\(entry.id).md")) {
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

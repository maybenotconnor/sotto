import ActivityKit
import SwiftUI
import WidgetKit

@main
struct SottoWidgetsBundle: WidgetBundle {
    var body: some Widget {
        SottoLiveActivityWidget()
    }
}

extension SottoActivityAttributes.Phase {
    var label: String {
        switch self {
        case .listening: "Listening"
        case .recording: "Recording"
        case .pausedByUser: "Paused by you"
        case .pausedBySystem: "Paused — call"
        }
    }

    var tint: Color {
        switch self {
        case .listening: .green
        case .recording: .red
        case .pausedByUser, .pausedBySystem: .orange
        }
    }

    /// Lock screen and expanded Island.
    var glyph: String {
        switch self {
        case .listening: "waveform"
        case .recording: "record.circle.fill"
        case .pausedByUser, .pausedBySystem: "pause.circle.fill"
        }
    }

    /// Compact and minimal Island slots want the unadorned forms.
    var compactGlyph: String {
        switch self {
        case .listening: "waveform"
        case .recording: "record.circle.fill"
        case .pausedByUser, .pausedBySystem: "pause.fill"
        }
    }
}

/// SPEC "Live Activity": lock screen = state label, elapsed timer, labeled conversation
/// count, Pause/Resume button. Dynamic Island compact/minimal = VAD-state glyph only
/// (no count); expanded = glyph, label, elapsed timer, Pause/Resume.
struct SottoLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SottoActivityAttributes.self) { context in
            HStack(spacing: 12) {
                Image(systemName: context.state.phase.glyph)
                    .font(.title2)
                    .foregroundStyle(context.state.phase.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.state.phase.label).font(.headline)
                    HStack(spacing: 6) {
                        Text(context.attributes.startedAt, style: .timer)
                        Text("· \(context.state.conversationCount) conversations")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    // M12 Task 12: one caption, only when a source is known (nil pre-M12 or
                    // phone-mic-only sessions) — lock-screen space is tight.
                    if let sourceLabel = context.state.sourceLabel {
                        Text(sourceLabel)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                // Ink capsule, not state-tinted: the action word carries the meaning
                // (ink-prominent spec extending the header spec's "no red button");
                // the glyph keeps the green/orange state signal.
                Button(intent: ToggleListeningIntent()) {
                    Text(context.state.phase.isPaused ? "Resume" : "Pause")
                        .font(.callout.bold())
                }
                .inkProminent()
            }
            .padding()
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: context.state.phase.glyph)
                        .foregroundStyle(context.state.phase.tint)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.phase.label).font(.headline)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.attributes.startedAt, style: .timer)
                        .font(.headline)
                        .monospacedDigit()
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Button(intent: ToggleListeningIntent()) {
                        Text(context.state.phase.isPaused ? "Resume" : "Pause")
                    }
                    .inkProminent()
                }
            } compactLeading: {
                Image(systemName: context.state.phase.compactGlyph)
                    .foregroundStyle(context.state.phase.tint)
            } compactTrailing: {
                EmptyView()
            } minimal: {
                Image(systemName: context.state.phase.compactGlyph)
                    .foregroundStyle(context.state.phase.tint)
            }
        }
    }
}

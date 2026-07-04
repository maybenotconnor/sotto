import ActivityKit
import SwiftUI
import WidgetKit

@main
struct SottoWidgetsBundle: WidgetBundle {
    var body: some Widget {
        SottoLiveActivityWidget()
    }
}

/// SPEC "Live Activity": state label, elapsed listening time, today's conversation count,
/// Pause/Resume button. Compact Dynamic Island: state glyph + count.
struct SottoLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SottoActivityAttributes.self) { context in
            HStack(spacing: 12) {
                Image(systemName: context.state.isPaused ? "pause.circle.fill" : "waveform.circle.fill")
                    .font(.title2)
                    .foregroundStyle(context.state.isPaused ? .orange : .green)
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.state.stateLabel).font(.headline)
                    HStack(spacing: 6) {
                        Text(context.attributes.startedAt, style: .timer)
                        Text("· \(context.state.conversationCount) conversations")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Button(intent: ToggleListeningIntent()) {
                    Text(context.state.isPaused ? "Resume" : "Pause")
                        .font(.callout.bold())
                }
                .buttonStyle(.borderedProminent)
                .tint(context.state.isPaused ? .green : .orange)
            }
            .padding()
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: context.state.isPaused ? "pause.circle.fill" : "waveform.circle.fill")
                        .foregroundStyle(context.state.isPaused ? .orange : .green)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.stateLabel).font(.headline)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("\(context.state.conversationCount)").font(.headline)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Button(intent: ToggleListeningIntent()) {
                        Text(context.state.isPaused ? "Resume" : "Pause")
                    }
                    .buttonStyle(.borderedProminent)
                }
            } compactLeading: {
                Image(systemName: context.state.isPaused ? "pause.fill" : "waveform")
            } compactTrailing: {
                Text("\(context.state.conversationCount)")
            } minimal: {
                Image(systemName: context.state.isPaused ? "pause.fill" : "waveform")
            }
        }
    }
}

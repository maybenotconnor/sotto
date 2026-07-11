import SwiftUI
import UIKit

/// The home header's state machine (moved from ContentView's HomeScreen, made internal
/// and purely derived so it is unit-testable). One segment-open case takes priority over
/// the raw pipeline status so the card morphs into "Recording…" instead of growing a
/// second header-like row (M9 decision, preserved by the 2026-07-10 header refresh).
enum HeaderState: Equatable {
    case idle
    case starting
    case interrupted(ListeningPipeline.HaltReason?)
    case listening(sessionStart: Date?)
    case segmentOpen(start: Date)

    init(
        segmentStart: Date?,
        status: ListeningPipeline.Status,
        haltReason: ListeningPipeline.HaltReason?,
        sessionStart: Date?
    ) {
        if let segmentStart {
            self = .segmentOpen(start: segmentStart)
        } else {
            switch status {
            case .idle: self = .idle
            case .starting: self = .starting
            case .interrupted: self = .interrupted(haltReason)
            case .listening, .recording, .silence:
                self = .listening(sessionStart: sessionStart)
            }
        }
    }

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

    /// Static subtitle shown when no timer runs (spec: idle only).
    var subtitle: String? {
        if case .idle = self { return "Ready to listen" }
        return nil
    }
}

/// The Porcelain hero: one glass surface carrying state dot + word, timer/subtitle, and a
/// compact action capsule (design: docs/superpowers/specs/2026-07-10-home-header-refresh-design.md).
/// Replaces HomeScreen's statusCard. Scrolls away with the list — the system mic indicator
/// and Live Activity carry the always-visible recording indication (pre-existing decision).
struct HeroCard: View {
    let model: AppModel
    let pipeline: ListeningPipeline
    let micDenied: Bool

    /// `model.settings` is UserDefaults-backed, not @Observable — @AppStorage observes the
    /// same defaults key so the unsupported-engine footnote updates when Settings changes
    /// the engine; nil (pre-M10 installs) falls back to the store's migrating getter.
    /// (Moved from HomeScreen with the banner fold-in.)
    @AppStorage("transcriptionEngine") private var engineRaw: String?
    private var onDeviceEngineSelected: Bool {
        let engine = engineRaw.flatMap(TranscriptionBackend.init(rawValue:))
            ?? model.settings.transcriptionEngine
        return engine == .speechAnalyzer
    }

    private var state: HeaderState {
        HeaderState(
            segmentStart: pipeline.currentSegmentStartDate,
            status: pipeline.status,
            haltReason: pipeline.haltReason,
            sessionStart: pipeline.sessionStartedAt)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 10) {
                if case .segmentOpen = state {
                    PulsingDot(color: .red)
                } else {
                    Circle().fill(state.dotColor).frame(width: 12, height: 12)
                }
                stateWord
                    .font(.title2.bold())
                    .foregroundStyle(Color("Ink"))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 8)
                actionButton
            }
            subtitleLine
            footnotes
        }
        .padding(16)
        .glassEffect(.regular, in: .rect(cornerRadius: 26))
        .background(Color("Porcelain").opacity(0.55), in: .rect(cornerRadius: 26))
    }

    /// M12: source suffix only when a wearable is paired — phone-mic-only users see the
    /// exact same label as before (SPEC "UI & surfacing"; carried over from statusCard).
    private var stateWord: Text {
        if let source = pipeline.activeSourceType, model.pairedDeviceName != nil {
            return Text("\(state.label) · \(source.displayName)")
        }
        return Text(state.label)
    }

    @ViewBuilder private var subtitleLine: some View {
        if let timerStart = state.timerStart {
            Text(timerStart, style: .timer)
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.leading, 22)
        } else if let subtitle = state.subtitle {
            Text(subtitle)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.leading, 22)
        }
    }

    private var actionButton: some View {
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
        .inkProminent()
        .disabled(micDenied && (pipeline.status == .idle || pipeline.status == .interrupted))
    }

    private var buttonLabel: String {
        switch pipeline.status {
        case .idle: "Start Listening"
        case .interrupted: "Resume"
        default: "Stop"
        }
    }

    /// The former full-weight banner stack, folded into the card as footnote rows —
    /// same copy, same actions, same trigger conditions (spec "Banners → footnotes").
    @ViewBuilder private var footnotes: some View {
        if hasFootnotes {
            Divider()
                .padding(.top, 12)
            VStack(alignment: .leading, spacing: 8) {
                if let notice = model.recoveryNotice {
                    FootnoteRow(
                        symbol: "exclamationmark.triangle", isWarning: true, text: notice,
                        actionLabel: "Dismiss") { model.dismissRecoveryNotice() }
                }
                if case .downloading(let fraction) = model.assetState {
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: fraction)
                        Text("Preparing on-device transcription — recordings are saved and will be transcribed when it's ready.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else if case .notInstalled = model.assetState {
                    FootnoteRow(
                        symbol: "arrow.down.circle",
                        text: "On-device transcription model not downloaded.",
                        actionLabel: "Download") { Task { await model.downloadSpeechModel() } }
                } else if case .failed = model.assetState {
                    FootnoteRow(
                        symbol: "arrow.down.circle", isWarning: true,
                        text: "Model download failed — check your connection.",
                        actionLabel: "Try again") { Task { await model.downloadSpeechModel() } }
                } else if case .unsupported = model.assetState, onDeviceEngineSelected {
                    FootnoteRow(
                        symbol: "exclamationmark.triangle",
                        text: "This device doesn't support on-device transcription. Select another transcription engine in Settings.")
                }
                if micDenied {
                    FootnoteRow(
                        symbol: "mic.slash", isWarning: true,
                        text: "Microphone access is off. Sotto can't listen without it.",
                        actionLabel: "Open Settings", action: openSettings)
                }
                if let reason = AppModel.bluetoothBannerReason(
                    pairedDeviceName: model.pairedDeviceName, connectionState: model.deviceConnectionState) {
                    // pairedDeviceKind is non-nil whenever the banner shows (name/kind are set
                    // together); the fallback is compiler-required. (Same pattern as the old banner.)
                    let deviceName = model.pairedDeviceKind?.displayName ?? "device"
                    FootnoteRow(
                        symbol: "antenna.radiowaves.left.and.right.slash", isWarning: true,
                        text: reason == .poweredOff
                            ? "Bluetooth is off — your \(deviceName) can't connect. Recording uses the iPhone mic."
                            : "Sotto needs Bluetooth permission to use your \(deviceName). Recording uses the iPhone mic.",
                        actionLabel: "Open Settings", action: openSettings)
                }
                if pipeline.diskGuardActive {
                    FootnoteRow(
                        symbol: "externaldrive.badge.exclamationmark", isWarning: true,
                        text: "Low disk space — new recordings are paused.")
                }
            }
            .padding(.top, 10)
        }
    }

    /// Mirrors every footnote condition above — gates the Divider so an all-clear card
    /// has no trailing hairline.
    private var hasFootnotes: Bool {
        if model.recoveryNotice != nil { return true }
        switch model.assetState {
        case .downloading, .notInstalled, .failed: return true
        case .unsupported: if onDeviceEngineSelected { return true }
        default: break
        }
        if micDenied { return true }
        if AppModel.bluetoothBannerReason(
            pairedDeviceName: model.pairedDeviceName, connectionState: model.deviceConnectionState) != nil {
            return true
        }
        return pipeline.diskGuardActive
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}

/// Pulsing dot for the card's segment-open state (moved verbatim from ContentView.swift).
struct PulsingDot: View {
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

/// The app icon's speech-line — a decaying waveform settling into a ruled line — as a
/// SwiftUI Shape. Centerline geometry is copied from the icon spec's 160-unit space
/// (docs/superpowers/specs/2026-07-10-app-icon-design.md) and fit-scaled into rect.
struct WaveMark: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 26, y: 52))
        path.addCurve(
            to: CGPoint(x: 36, y: 42),
            control1: CGPoint(x: 28.5, y: 47.5), control2: CGPoint(x: 32, y: 42))
        path.addCurve(
            to: CGPoint(x: 54, y: 60),
            control1: CGPoint(x: 44, y: 42), control2: CGPoint(x: 46, y: 60))
        path.addCurve(
            to: CGPoint(x: 68, y: 47),
            control1: CGPoint(x: 61, y: 60), control2: CGPoint(x: 61, y: 47))
        path.addCurve(
            to: CGPoint(x: 78, y: 52),
            control1: CGPoint(x: 72, y: 47), control2: CGPoint(x: 74, y: 52))
        path.addLine(to: CGPoint(x: 134, y: 52))

        let bounds = CGRect(x: 26, y: 42, width: 108, height: 18)
        let scale = min(rect.width / bounds.width, rect.height / bounds.height)
        let transform = CGAffineTransform.identity
            .translatedBy(x: rect.midX, y: rect.midY)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -bounds.midX, y: -bounds.midY)
        return path.applying(transform)
    }
}

/// One notice line inside the card: leading symbol, footnote text, optional trailing bold
/// action. Warning rows tint the symbol red, not the body text (spec). Explicit button
/// style is required — the row lives inside a List row that already contains other buttons.
private struct FootnoteRow: View {
    let symbol: String
    var isWarning = false
    let text: String
    var actionLabel: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .font(.footnote)
                .foregroundStyle(isWarning ? Color.red : Color.secondary)
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let actionLabel, let action {
                Button(actionLabel, action: action)
                    .font(.footnote.bold())
                    .buttonStyle(.plain)
                    .foregroundStyle(Color("Ink"))
            }
        }
    }
}

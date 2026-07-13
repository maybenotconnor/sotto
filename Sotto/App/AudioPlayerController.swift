import AVFoundation
import Observation

/// AVAudioPlayer wrapper for the detail screen.
///
/// Playback must put the shared `AVAudioSession` into an *audible* state before `play()`, but
/// must NOT tear down a live phone-mic capture (SPEC: playback must not disturb the live
/// pipeline). It deliberately does NOT infer "a capture is live" from the session *category*:
/// the recording path (`PhoneMicAudioSource`) leaves the category `.playAndRecord` even after it
/// deactivates on stop, so once the user has ever listened the category stays `.playAndRecord`
/// for the rest of the process — a useless signal. Instead the caller passes the pipeline's live
/// state (`phoneMicCapturing`, from `ListeningPipeline.activeSourceType == .phoneMic`, plus
/// `pipelineActive` for the non-idle status that guards the failover window).
@MainActor
@Observable
final class AudioPlayerController {
    private var player: AVAudioPlayer?
    private var ticker: Task<Void, Never>?
    /// True while we hold a playback-owned `.playback` session that stop() must deactivate.
    /// False when a live phone-mic capture owns the session (we must not tear it down).
    private var ownsPlaybackSession = false
    private(set) var isPlaying = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    var rate: Float = 1.0 {
        didSet { player?.rate = rate }
    }

    func load(url: URL) {
        player = try? AVAudioPlayer(contentsOf: url)
        player?.enableRate = true
        duration = player?.duration ?? 0
    }

    /// `phoneMicCapturing` must be true iff a live phone-mic capture is running right now
    /// (`ListeningPipeline.activeSourceType == .phoneMic`); `pipelineActive` iff the pipeline is
    /// in any non-idle status. Together they identify a live `.playAndRecord` session this player
    /// must not reconfigure (see `activatePlaybackSession`).
    func togglePlay(phoneMicCapturing: Bool, pipelineActive: Bool) {
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
            ticker?.cancel()
        } else {
            activatePlaybackSession(phoneMicCapturing: phoneMicCapturing, pipelineActive: pipelineActive)
            player.rate = rate
            player.play()
            isPlaying = true
            ticker = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(250))
                    guard let self, let player = self.player else { return }
                    self.currentTime = player.currentTime
                    // Natural end-of-track: mirror stop()'s teardown so the owned .playback
                    // session is deactivated (letting other apps' audio resume) rather than
                    // lingering until the screen is dismissed.
                    if !player.isPlaying {
                        self.isPlaying = false
                        self.deactivatePlaybackSession()
                        return
                    }
                }
            }
        }
    }

    func seek(to time: TimeInterval) {
        player?.currentTime = max(0, min(time, duration))
        currentTime = player?.currentTime ?? 0
    }

    func skip(_ delta: TimeInterval) {
        seek(to: currentTime + delta)
    }

    func stop() {
        ticker?.cancel()
        player?.stop()
        isPlaying = false
        deactivatePlaybackSession()
    }

    /// Put the shared session into an audible state before `play()`.
    ///
    /// - When a phone-mic capture is live it owns a `.playAndRecord` session we must not disturb,
    ///   so keep the category and only force the loudspeaker (record mode routes to the quiet
    ///   earpiece receiver) — but not when a headset is attached, so we neither bypass headphones
    ///   nor blast a private recording out loud. The override is applied AFTER `setActive`, since
    ///   it only affects the currently active route.
    /// - Otherwise (idle, or a wearable capture that uses no `AVAudioSession`) adopt a clean
    ///   `.playback` session: routes to the loudspeaker or attached headphones and ignores the
    ///   Ring/Silent switch. This is the common browse-and-play path.
    private func activatePlaybackSession(phoneMicCapturing: Bool, pipelineActive: Bool) {
        let session = AVAudioSession.sharedInstance()
        // Keep a live phone-mic `.playAndRecord` session intact rather than reconfiguring it to
        // `.playback` (which would cut the running engine's mic input). `phoneMicCapturing` is the
        // steady-state truth; the extra `pipelineActive && category == .playAndRecord` term also
        // covers the brief failover window where `activeSourceType` still lags the just-started
        // phone-mic engine — erring toward never disturbing a live recording. When idle the
        // leftover `.playAndRecord` category alone does NOT trigger this (pipelineActive is false),
        // so the common browse-and-play path still gets a clean `.playback` session.
        let keepRecordSession = phoneMicCapturing
            || (pipelineActive && session.category == .playAndRecord)
        if keepRecordSession {
            try? session.setActive(true)
            if !hasHeadphoneOutput(session) {
                try? session.overrideOutputAudioPort(.speaker)
            }
            ownsPlaybackSession = false
        } else {
            try? session.setCategory(.playback, mode: .spokenAudio)
            try? session.setActive(true)
            ownsPlaybackSession = true
        }
    }

    /// Undo `activatePlaybackSession` on stop. Deactivate only a session we actually own AND that
    /// no capture has since taken over (category still `.playback`); otherwise a capture owns the
    /// session now, so just drop any loudspeaker override we added rather than tearing it down.
    private func deactivatePlaybackSession() {
        let session = AVAudioSession.sharedInstance()
        if ownsPlaybackSession, session.category == .playback {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
        } else if !ownsPlaybackSession {
            try? session.overrideOutputAudioPort(.none)
        }
        ownsPlaybackSession = false
    }

    /// Whether audio is currently routed to a headset (wired or wireless), in which case we must
    /// not force the built-in loudspeaker.
    private func hasHeadphoneOutput(_ session: AVAudioSession) -> Bool {
        session.currentRoute.outputs.contains { output in
            switch output.portType {
            case .headphones, .bluetoothA2DP, .bluetoothLE, .bluetoothHFP,
                 .airPlay, .carAudio, .usbAudio:
                return true
            default:
                return false
            }
        }
    }
}

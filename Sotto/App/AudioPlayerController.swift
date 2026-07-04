import AVFoundation
import Observation

/// AVAudioPlayer wrapper for the detail screen. Playback deliberately does NOT touch the
/// shared audio session (SPEC: playback must not disturb the live pipeline — the session
/// is already .playAndRecord).
@MainActor
@Observable
final class AudioPlayerController {
    private var player: AVAudioPlayer?
    private var ticker: Task<Void, Never>?
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

    func togglePlay() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
            ticker?.cancel()
        } else {
            player.rate = rate
            player.play()
            isPlaying = true
            ticker = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(250))
                    guard let self, let player = self.player else { return }
                    self.currentTime = player.currentTime
                    if !player.isPlaying { self.isPlaying = false; return }
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
    }
}

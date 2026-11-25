import AVFoundation
import Observation

/// Plays the selected recording from a transcript turn and reports the time,
/// so the view can highlight the turn being spoken. One recording at a time.
@Observable @MainActor
final class TranscriptPlayer {
    /// The recording loaded for playback; nil when the player is closed.
    private(set) var directory: URL?
    private(set) var isPlaying = false
    /// Seconds on the meeting clock.
    private(set) var time: Double = 0 { didSet { updateActiveTurn() } }
    /// The turn being spoken at `time`; changes far less often than `time`,
    /// so the transcript redraws only when the highlight moves.
    private(set) var activeTurn: Int?
    /// Turns of the loaded recording, for `activeTurn`.
    var turns: [TranscriptTurn] = [] { didSet { updateActiveTurn() } }
    private(set) var duration: Double = 0
    private(set) var error: String?

    @ObservationIgnored private var player: AVPlayer?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var loading: Task<Void, Never>?

    /// Plays `directory` from `seconds`, loading its audio first when another
    /// recording (or none) is loaded.
    func play(_ directory: URL, tracks: [TranscriptPlayback.Track], turns: [TranscriptTurn], from seconds: Double) {
        if self.directory != directory { stop() }
        self.directory = directory
        self.turns = turns
        time = seconds
        if let player {
            seek(player, to: seconds)
            player.play()
            isPlaying = true
            return
        }
        isPlaying = true
        error = nil
        loading?.cancel()
        loading = Task { [weak self] in
            do {
                let composition = try await TranscriptPlayback.composition(tracks)
                guard let self, !Task.isCancelled, self.directory == directory else { return }
                self.start(AVPlayerItem(asset: composition), duration: composition.duration.seconds)
            } catch {
                guard let self, !Task.isCancelled, self.directory == directory else { return }
                self.isPlaying = false
                self.error = (error as? TranscriptionFailure)?.description ?? error.localizedDescription
            }
        }
    }

    func toggle() {
        guard let player else { return }
        if isPlaying { player.pause(); isPlaying = false; return }
        if time >= duration - 0.05 { seek(player, to: 0) }
        player.play()
        isPlaying = true
    }

    /// Scrubbing: moves without changing play or pause.
    func seek(to seconds: Double) {
        time = min(max(0, seconds), duration)
        if let player { seek(player, to: time) }
    }

    /// Closes the player and releases the audio files.
    func stop() {
        loading?.cancel()
        loading = nil
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        timeObserver = nil
        endObserver = nil
        player?.pause()
        player = nil
        directory = nil
        isPlaying = false
        time = 0
        duration = 0
        error = nil
        turns = []
    }

    private func updateActiveTurn() {
        let active = directory == nil ? nil : TranscriptPlayback.activeTurn(turns, at: time)
        if active != activeTurn { activeTurn = active }
    }

    private func start(_ item: AVPlayerItem, duration: Double) {
        let player = AVPlayer(playerItem: item)
        self.player = player
        self.duration = duration
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 10), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, self.player === player else { return }
                self.time = time.seconds
                // Observation notifies on every set; only a change redraws.
                if self.isPlaying != (player.rate != 0) { self.isPlaying = player.rate != 0 }
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.player === player else { return }
                self.isPlaying = false
                self.time = self.duration
            }
        }
        seek(player, to: time)
        player.play()
    }

    private func seek(_ player: AVPlayer, to seconds: Double) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 48_000), toleranceBefore: .zero, toleranceAfter: .zero)
    }
}

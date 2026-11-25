import AVFoundation
import Foundation

/// Plays a recording on its transcript's meeting clock. Read-only: it opens
/// the audio files for reading and never writes to the recording's folder.
enum TranscriptPlayback {
    /// An audio file and where its first sample sits on the meeting clock.
    struct Track: Equatable, Sendable {
        let url: URL
        let offset: Double
    }

    enum Source: Equatable, Sendable {
        case tracks([Track])
        /// No usable audio; the reason is shown instead of play buttons.
        case unavailable(String)
    }

    /// `meeting-audio.wav` when present: the aligned mix ElevenLabs
    /// transcribed, already on the meeting clock. Otherwise the tracks in
    /// meta.json at their start offsets, as Parakeet and older ElevenLabs
    /// transcripts shift their segments and `MeetingAudio` aligns its mix.
    static func source(in directory: URL) -> Source {
        let fm = FileManager.default
        let mixed = directory.appendingPathComponent(MeetingAudio.filename)
        if fm.isReadableFile(atPath: mixed.path) { return .tracks([Track(url: mixed, offset: 0)]) }
        guard let meta = try? SessionMeta.read(from: directory) else {
            return .unavailable("Its meta.json is missing or unreadable, so the audio can’t be lined up with the transcript.")
        }
        let tracks = meta.tracks.compactMap { track -> Track? in
            let url = directory.appendingPathComponent(track.file)
            guard fm.isReadableFile(atPath: url.path), track.offsetMs >= 0 else { return nil }
            return Track(url: url, offset: Double(track.offsetMs) / 1000)
        }
        return tracks.isEmpty ? .unavailable("Its audio files are missing or unreadable.") : .tracks(tracks)
    }

    /// One audio track per file, each starting at its offset, so they play
    /// mixed on the meeting clock.
    static func composition(_ tracks: [Track]) async throws -> AVComposition {
        let composition = AVMutableComposition()
        for track in tracks {
            let asset = AVURLAsset(url: track.url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            guard let audio = try await asset.loadTracks(withMediaType: .audio).first,
                  let target = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { continue }
            let range = try await audio.load(.timeRange)
            try target.insertTimeRange(range, of: audio, at: CMTime(seconds: track.offset, preferredTimescale: 48_000))
        }
        guard composition.duration.seconds > 0 else { throw TranscriptionFailure("This recording’s audio is empty or can’t be read.") }
        return composition
    }

    /// The turn being spoken at `time`: of the turns that cover it, the one
    /// that started last (an interjection over a longer turn); in a pause, the
    /// turn that ended last before it; before the first turn, none.
    static func activeTurn(_ turns: [TranscriptTurn], at time: Double) -> Int? {
        var covering: TranscriptTurn?, previous: TranscriptTurn?
        for turn in turns where turn.start <= time {
            if time < turn.end {
                if covering.map({ turn.start >= $0.start }) ?? true { covering = turn }
            } else if previous.map({ turn.end > $0.end || (turn.end == $0.end && turn.start >= $0.start) }) ?? true {
                previous = turn
            }
        }
        return (covering ?? previous)?.id
    }
}

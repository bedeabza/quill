import ArgumentParser
import Darwin
import Foundation

struct RefreshSpeakers: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "refresh",
        abstract: "Re-evaluate names from cached Scribe diarization and recorded meeting UI. No uploads or local diarization.")
    @Argument var recording: String
    @Option(help: "Unavailable for cached Scribe results; regenerate the cloud transcript to change diarization.") var remoteSpeakers: Int?
    @Option(help: "Write a preview to a new folder instead of updating the recording.") var output: String?

    func run() throws {
        let command = self
        Task {
            do { try await command.refresh(); Darwin.exit(0) }
            catch {
                FileHandle.standardError.write(Data("Speaker refresh failed: \(error)\n".utf8))
                Darwin.exit(1)
            }
        }
        dispatchMain()
    }

    func refresh() async throws {
        guard remoteSpeakers == nil else {
            throw ValidationError("Speaker refresh never runs local diarization. Regenerate the ElevenLabs transcript to change its speaker separation.")
        }
        let fm = FileManager.default
        let directory = URL(fileURLWithPath: (recording as NSString).expandingTildeInPath).standardizedFileURL
        let lock = open(directory.appendingPathComponent(".postprocess.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw ValidationError("Could not lock this recording.") }
        defer { flock(lock, LOCK_UN); close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw ValidationError("Transcript processing is already running.") }
        var meta = try SessionMeta.read(from: directory)
        let transcriptURL = directory.appendingPathComponent("transcript.json")
        let original = try Data(contentsOf: transcriptURL)
        let transcript = try JSONDecoder().decode(Transcript.self, from: original)
        guard transcript.engine == "elevenlabs", transcript.variant == "elevenlabs_original" else {
            throw ValidationError("This recording needs Scribe diarization. Regenerate it with quill transcribe --engine elevenlabs --force; older undiarized caches cannot be refreshed locally.")
        }
        let namedURL = directory.appendingPathComponent("transcript-named.json")
        let previousNamed = try? Data(contentsOf: namedURL)
        if let previousNamed, let named = try? JSONDecoder().decode(Transcript.self, from: previousNamed),
           named.segments.contains(where: { $0.attribution == "manual" }) {
            throw ValidationError("Manual speaker corrections are present; refusing to overwrite them.")
        }
        var tracks: [ElevenLabsTranscripts.TrackResult] = []
        let mixed = transcript.speaker_detection?["meeting"] != nil || transcript.segments.contains(where: { $0.source == "meeting" })
        let prepared = mixed ? try MeetingAudio.cached(in: directory, meta: meta) : nil
        if mixed && prepared == nil {
            throw ValidationError("The combined recording or its source manifest changed. Regenerate the ElevenLabs transcript; speaker refresh never rebuilds audio or uploads it.")
        }
        let sourceTracks = mixed ? [SessionMeta.Track(file: MeetingAudio.filename, speaker: "meeting", offsetMs: 0)] : meta.tracks
        for track in sourceTracks {
            let cacheURL = directory.appendingPathComponent("elevenlabs-\(track.file).json")
            let cache = try JSONDecoder().decode(ElevenLabsEngine.Cache.self, from: Data(contentsOf: cacheURL))
            guard cache.version == ElevenLabsEngine.cacheVersion, cache.model == transcript.model,
                  cache.audioSHA256 == (try ElevenLabsEngine.fingerprint(directory.appendingPathComponent(track.file))) else {
                throw ValidationError("Cached Scribe diarization does not match this audio and model. Regenerate the cloud transcript.")
            }
            tracks.append(.init(track: track, segments: try ElevenLabsEngine.segments(cache.response), meetingAudio: prepared?.manifest))
        }
        let observationText = (try? String(contentsOf: directory.appendingPathComponent("speaker-observations.jsonl"), encoding: .utf8)) ?? ""
        let observations = try observationText.split(separator: "\n").map { try JSONDecoder().decode(SpeakerObservation.self, from: Data($0.utf8)) }
        var roster = transcript.participant_roster ?? meta.participantRoster ?? ParticipantRoster(audio_started_at: meta.audioStartedAt ?? 0)
        for observation in observations { roster.observe(observation, localName: meta.localSpeakerName) }
        meta.meetingTitle = transcript.meeting_title ?? meta.meetingTitle
        let built = ElevenLabsTranscripts.build(meta: meta, tracks: tracks, roster: roster, observations: observations, createdAt: transcript.created_at)
        // Refresh is an attribution operation, never a text or diarization edit.
        guard built.original.segments.count == transcript.segments.count,
              zip(built.original.segments, transcript.segments).allSatisfy({ lhs, rhs in
                  lhs.text == rhs.text && lhs.start_ms == rhs.start_ms && lhs.end_ms == rhs.end_ms
                      && lhs.speaker == rhs.speaker && lhs.provider_speaker_id == rhs.provider_speaker_id
                      && rhs.speaker_name == nil && rhs.attribution == "elevenlabs"
              }) else { throw ValidationError("Transcript content or speakers were edited; refusing to replace those edits.") }
        var named = built.named
        if named != nil {
            named?.participant_roster = transcript.participant_roster
            named?.meeting_title = transcript.meeting_title
        }
        let result = ElevenLabsTranscripts.Output(original: transcript, named: named, report: built.report, analysis: built.analysis)
        let target: URL
        let backup: URL?
        let files = ["transcript.json", "transcript.md", "transcript-named.json", "transcript-named.md", "speaker-mapping.json", "speaker-analysis.json"]
        if let output {
            target = URL(fileURLWithPath: (output as NSString).expandingTildeInPath).standardizedFileURL
            guard !fm.fileExists(atPath: target.path) else { throw ValidationError("Preview folder already exists.") }
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
            backup = nil
        } else {
            guard try Data(contentsOf: transcriptURL) == original,
                  (try? Data(contentsOf: namedURL)) == previousNamed else {
                throw ValidationError("Recording changed during refresh; no corrections were written.")
            }
            target = directory
            let saved = directory.appendingPathComponent("speaker-refresh-backup-" + UUID().uuidString)
            try fm.createDirectory(at: saved, withIntermediateDirectories: false)
            for file in files where fm.fileExists(atPath: directory.appendingPathComponent(file).path) {
                try fm.copyItem(at: directory.appendingPathComponent(file), to: saved.appendingPathComponent(file))
            }
            backup = saved
        }
        do { try result.write(to: target) }
        catch {
            if let backup {
                for file in files {
                    let saved = backup.appendingPathComponent(file), destination = target.appendingPathComponent(file)
                    if fm.fileExists(atPath: saved.path) { try Data(contentsOf: saved).write(to: destination, options: .atomic) }
                    else if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
                }
            }
            throw error
        }
        print(target.appendingPathComponent(result.named == nil ? "transcript.md" : "transcript-named.md").path)
    }
}

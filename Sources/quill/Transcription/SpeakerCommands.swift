import ArgumentParser
import Foundation
import FluidAudio
import Darwin

struct Transcribe: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Transcribe a completed recording with the selected engine, without running cleanup or the archive hook.")
    @Argument(help: "Completed recording folder containing meta.json and audio.") var recording: String
    @Option(help: "Write a disposable preview into a new folder, leaving the recording unchanged.") var output: String?
    @Flag(help: "Replace an existing transcript. Speaker IDs and manual names will be regenerated.") var force = false
    @Flag(help: "Skip speaker separation.") var noSpeakers = false
    @Flag(help: "Require cached local models. Reject cloud transcription and prevent downloads.") var offline = false
    @Option(help: "Use parakeet (local) or elevenlabs (uploads audio) for this run without changing the menu setting.") var engine: TranscriptionEngineKind?
    @Option(help: "Known number of speaking people on the remote audio track. Normally inferred automatically.") var remoteSpeakers: Int?

    func run() throws {
        let command = self
        Task {
            do { try await command.transcribe(); Darwin.exit(0) }
            catch {
                FileHandle.standardError.write(Data("Transcription failed: \(error)\n".utf8))
                Darwin.exit(1)
            }
        }
        dispatchMain()
    }

    private func transcribe() async throws {
        if let remoteSpeakers, remoteSpeakers < 1 || remoteSpeakers > 100 {
            throw ValidationError("Remote speaker count must be between 1 and 100.")
        }
        if offline && (engine?.rawValue ?? Config.transcriptionEngine()) == "elevenlabs" {
            throw ValidationError("ElevenLabs requires uploading audio. Use --engine parakeet with --offline.")
        }
        if offline { ModelHub.offlineMode = true }
        let original = URL(fileURLWithPath: (recording as NSString).expandingTildeInPath).standardizedFileURL
        _ = try SessionMeta.read(from: original)
        let dir: URL
        let fm = FileManager.default
        if let output {
            dir = URL(fileURLWithPath: (output as NSString).expandingTildeInPath).standardizedFileURL
            guard !fm.fileExists(atPath: dir.path) else { throw ValidationError("Preview folder already exists; choose a new path.") }
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            for file in ["meta.json", "speaker-observations.jsonl", "participants.json"] where fm.fileExists(atPath: original.appendingPathComponent(file).path) {
                try fm.copyItem(at: original.appendingPathComponent(file), to: dir.appendingPathComponent(file))
            }
            for file in ["mic.caf", "system.caf"] where fm.fileExists(atPath: original.appendingPathComponent(file).path) {
                try fm.createSymbolicLink(at: dir.appendingPathComponent(file), withDestinationURL: original.appendingPathComponent(file))
            }
        } else {
            dir = original
            if fm.fileExists(atPath: dir.appendingPathComponent("transcript.json").path), !force {
                throw ValidationError("Transcript already exists. Use --output for a preview or --force to regenerate it.")
            }
        }
        try await TranscriptionCoordinator().transcribe(dir, detectSpeakers: !noSpeakers, remoteSpeakerCount: remoteSpeakers,
                                                        engineOverride: engine, offline: offline)
        print(dir.appendingPathComponent("transcript.md").path)
    }
}

struct Speakers: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Inspect and correct speaker labels.", subcommands: [LabelSpeaker.self, RefreshSpeakers.self])
}

struct LabelSpeaker: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "label", abstract: "Name every turn of one speaker in a completed transcript.")
    @Argument var recording: String
    @Option(help: "Speaker ID from transcript.json, for example system_1.") var speaker: String?
    @Flag(help: "Explicitly confirm that all remote speech in this recording belongs to this one person.") var soleRemoteSpeaker = false
    @Option(help: "Verified speaker name.") var name: String

    func run() throws {
        guard (speaker != nil) != soleRemoteSpeaker else {
            throw ValidationError("Choose either --speaker or --sole-remote-speaker.")
        }
        guard let name = SpeakerAttribution.cleanName(name) else { throw ValidationError("Enter a non-empty speaker name without line breaks.") }
        let dir = URL(fileURLWithPath: (recording as NSString).expandingTildeInPath)
        let url = dir.appendingPathComponent("transcript.json")
        let fm = FileManager.default
        let lock = open(dir.appendingPathComponent(".postprocess.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw ValidationError("Could not lock this transcript.") }
        defer { flock(lock, LOCK_UN); close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw ValidationError("Transcript processing is already running.") }
        let original = try Data(contentsOf: url)
        var transcript = try JSONDecoder().decode(Transcript.self, from: original)
        func matches(_ segment: Transcript.Segment) -> Bool {
            soleRemoteSpeaker ? (segment.source == "system" || segment.speaker == "them") : segment.speaker == speaker
        }
        guard transcript.segments.contains(where: matches),
              soleRemoteSpeaker || !["them", "system_unknown", "mic_unknown"].contains(speaker ?? "") else {
            throw ValidationError("Choose a separated speaker ID; mixed or unknown speech cannot receive a person's name.")
        }
        let meta = try SessionMeta.read(from: dir)
        var roster = transcript.participant_roster ?? meta.participantRoster ?? ParticipantRoster(audio_started_at: meta.audioStartedAt ?? 0)
        if soleRemoteSpeaker {
            // The explicit confirmation is durable evidence, including for
            // intervals where active-speaker UI and acoustic VAD were missing.
            roster.confirmed_sole_remote_speaker = name
            let start = roster.audio_started_at
            let end = start + Double(transcript.segments.map(\.end_ms).max() ?? 0) / 1000
            roster.participants = [.init(name: name, is_local: false, first_seen: start, last_seen: end, sources: ["user_confirmation"])]
            if let localName = meta.localSpeakerName {
                roster.participants.insert(.init(name: localName, is_local: true, first_seen: start, last_seen: end,
                                                 sources: ["local_microphone", "user_confirmation"]), at: 0)
            }
        }
        let backup = dir.appendingPathComponent("speaker-label-backup-\(UUID().uuidString)")
        try fm.createDirectory(at: backup, withIntermediateDirectories: false)
        let files = ["transcript.json", "transcript.md", "participants.json", "postprocess.json"]
        for file in files where fm.fileExists(atPath: dir.appendingPathComponent(file).path) {
            try fm.copyItem(at: dir.appendingPathComponent(file), to: backup.appendingPathComponent(file))
        }
        for index in transcript.segments.indices where matches(transcript.segments[index]) {
            transcript.segments[index].speaker_name = name
            transcript.segments[index].attribution = "manual"
            if soleRemoteSpeaker {
                transcript.segments[index].speaker = SpeakerAttribution.namedSpeakerID(.init(name: name, source: "manual", evidence_count: 1), source: "system")
            }
        }
        transcript.schema_version = 2
        transcript.participant_roster = roster
        guard try Data(contentsOf: url) == original else { throw ValidationError("Transcript changed during labelling.") }
        do {
            try transcript.write(to: dir)
            try JSONEncoder().encode(roster).write(to: dir.appendingPathComponent("participants.json"), options: .atomic)
        } catch {
            for file in ["transcript.json", "transcript.md", "participants.json"] {
                let saved = backup.appendingPathComponent(file), target = dir.appendingPathComponent(file)
                if fm.fileExists(atPath: saved.path) { try Data(contentsOf: saved).write(to: target, options: .atomic) }
                else if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            }
            throw error
        }
        print("Backup: \(backup.path)")
        print("Labelled \(speaker ?? "the verified sole remote speaker") as \(name). Run the archive sync to publish the correction.")
    }
}

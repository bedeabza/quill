import ArgumentParser
import Foundation

struct RefreshSpeakers: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "refresh",
        abstract: "Refresh speaker labels using cached ElevenLabs words, local audio, and recorded meeting UI. No uploads or cleanup.")
    @Argument var recording: String
    @Option(help: "Known remote speaker count; reruns local speaker separation when provided.") var remoteSpeakers: Int?
    @Option(help: "Write a preview to a new folder instead of updating the recording.") var output: String?

    func run() throws {
        if let remoteSpeakers, !(1...100).contains(remoteSpeakers) { throw ValidationError("Remote speaker count must be between 1 and 100.") }
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
        let fm = FileManager.default
        let directory = URL(fileURLWithPath: (recording as NSString).expandingTildeInPath).standardizedFileURL
        let meta = try SessionMeta.read(from: directory)
        guard let track = meta.tracks.first(where: { $0.source == "system" }), let started = meta.audioStartedAt else {
            throw ValidationError("This recording needs a system track and its start timestamp.")
        }
        let transcriptURL = directory.appendingPathComponent("transcript.json")
        let original = try Data(contentsOf: transcriptURL)
        let transcript = try JSONDecoder().decode(Transcript.self, from: original)
        guard transcript.engine == "elevenlabs" else { throw ValidationError("Speaker refresh currently requires cached ElevenLabs word timestamps.") }
        let remote = transcript.segments.filter { $0.source == "system" }
        guard !remote.contains(where: { $0.attribution == "manual" }) else {
            throw ValidationError("Manual speaker corrections are present; refusing to overwrite them.")
        }
        let audio = directory.appendingPathComponent(track.file)
        let cacheURL = directory.appendingPathComponent("elevenlabs-\(track.file).json")
        let cache = try JSONDecoder().decode(ElevenLabsEngine.Cache.self, from: Data(contentsOf: cacheURL))
        guard cache.version == 1, cache.model == transcript.model,
              cache.audioSHA256 == (try ElevenLabsEngine.fingerprint(audio)) else {
            throw ValidationError("The cached word timestamps do not match this audio and model.")
        }
        let words = try ElevenLabsEngine.segments(cache.response)
        func normalized(_ strings: [String]) -> String { strings.joined(separator: " ").split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        guard normalized(remote.map(\.text)) == normalized(words.map(\.text)) else {
            throw ValidationError("Transcript wording has been edited since transcription; refusing to replace those edits.")
        }
        let analysisURL = directory.appendingPathComponent("speaker-analysis.json")
        let originalAnalysis = try Data(contentsOf: analysisURL)
        var analysis = try JSONDecoder().decode(SpeakerAnalysis.self, from: originalAnalysis)
        let offset = Double(track.offsetMs) / 1000
        let turns: [SpeakerTurn]
        if let remoteSpeakers {
            FileHandle.standardError.write(Data("Separating \(remoteSpeakers) remote speakers from local audio...\n".utf8))
            turns = try await SpeakerDiarizer.analyze(audio, source: "system", speakerCount: remoteSpeakers).turns
        } else {
            turns = analysis.turns.filter { $0.speaker_id.hasPrefix("system_") }
                .map { SpeakerTurn(speaker_id: $0.speaker_id, start: $0.start - offset, end: $0.end - offset) }
        }
        let observationText = try String(contentsOf: directory.appendingPathComponent("speaker-observations.jsonl"), encoding: .utf8)
        let observations = try observationText.split(separator: "\n").map { try JSONDecoder().decode(SpeakerObservation.self, from: Data($0.utf8)) }
        let spans = SpeakerAttribution.nameSpans(turns: turns, observations: observations, audioStartedAt: started + offset, segments: words)
        guard !spans.isEmpty else { throw ValidationError("No recorded active-speaker names are available for this recording.") }
        let identities = SpeakerAttribution.voiceNames(turns: turns, spans: spans)
        let refreshed = SpeakerAttribution.align(words, turns: turns, source: "system", offset: offset,
                                                  namedSpans: spans, voiceIdentities: identities)
        guard normalized(refreshed.map(\.text)) == normalized(remote.map(\.text)) else { throw ValidationError("Speaker refresh changed the transcript text.") }
        var updated = transcript
        updated.segments = (transcript.segments.filter { $0.source != "system" } + refreshed).sorted { $0.start_ms < $1.start_ms }
        analysis.turns = analysis.turns.filter { !$0.speaker_id.hasPrefix("system_") }
            + turns.map { SpeakerTurn(speaker_id: $0.speaker_id, start: $0.start + offset, end: $0.end + offset) }
        analysis.named_spans = spans.map { NamedSpeakerSpan(start: $0.start + offset, end: $0.end + offset, identity: $0.identity) }
        analysis.voice_identities = identities
        analysis.names = analysis.names.filter { !$0.key.hasPrefix("system_") }
        for span in spans { analysis.names[SpeakerAttribution.namedSpeakerID(span.identity, source: "system")] = span.identity }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        func wordCount(_ segments: [Transcript.Segment]) -> Int {
            segments.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }
        }
        let report: [String: Any] = ["created_at": ISO8601DateFormatter().string(from: Date()),
            "before_remote_segments": remote.count, "after_remote_segments": refreshed.count,
            "before_unnamed_segments": remote.filter { $0.speaker_name == nil }.count,
            "after_unnamed_segments": refreshed.filter { $0.speaker_name == nil }.count,
            "confirmed_names": Array(Set(refreshed.compactMap(\.speaker_name))).sorted(),
            "before_named_words": wordCount(remote.filter { $0.speaker_name != nil }),
            "after_named_words": wordCount(refreshed.filter { $0.speaker_name != nil }),
            "total_remote_words": wordCount(refreshed),
            "text_preserved": true, "word_timestamps_reused": true, "audio_uploaded": false]
        let target: URL
        var backup: URL?
        var previousReport: Data?
        if let output {
            target = URL(fileURLWithPath: (output as NSString).expandingTildeInPath).standardizedFileURL
            guard !fm.fileExists(atPath: target.path) else { throw ValidationError("Preview folder already exists.") }
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
        } else {
            guard try Data(contentsOf: transcriptURL) == original,
                  try Data(contentsOf: analysisURL) == originalAnalysis else { throw ValidationError("Recording changed during refresh; no corrections were written.") }
            target = directory
            let backupURL = directory.appendingPathComponent("speaker-refresh-backup-" + UUID().uuidString)
            try fm.createDirectory(at: backupURL, withIntermediateDirectories: false)
            for file in ["transcript.json", "transcript.md", "speaker-analysis.json", "postprocess.json"] {
                let url = directory.appendingPathComponent(file)
                if fm.fileExists(atPath: url.path) { try fm.copyItem(at: url, to: backupURL.appendingPathComponent(file)) }
            }
            backup = backupURL
            previousReport = try? Data(contentsOf: directory.appendingPathComponent("speaker-refresh.json"))
            FileHandle.standardError.write(Data("Backup: \(backupURL.path)\n".utf8))
        }
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        do {
            try updated.write(to: target)
            try encoder.encode(analysis).write(to: target.appendingPathComponent("speaker-analysis.json"), options: .atomic)
            try data.write(to: target.appendingPathComponent("speaker-refresh.json"), options: .atomic)
        } catch {
            if let backup {
                for file in ["transcript.json", "transcript.md", "speaker-analysis.json"] {
                    let saved = backup.appendingPathComponent(file)
                    if fm.fileExists(atPath: saved.path) { try Data(contentsOf: saved).write(to: target.appendingPathComponent(file), options: .atomic) }
                }
                let reportURL = target.appendingPathComponent("speaker-refresh.json")
                if let previousReport { try previousReport.write(to: reportURL, options: .atomic) }
                else if fm.fileExists(atPath: reportURL.path) { try fm.removeItem(at: reportURL) }
            }
            throw error
        }
        print(String(decoding: data, as: UTF8.self))
        print(target.appendingPathComponent("transcript.md").path)
    }
}

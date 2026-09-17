import ArgumentParser
import Foundation
import Darwin

struct SpeakerMemoryCommands: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "memory", abstract: "Manage local speaker voice fingerprints.",
        subcommands: [SpeakerMemoryStatus.self, SpeakerMemoryLearn.self, SpeakerMemoryForget.self], defaultSubcommand: SpeakerMemoryStatus.self)
}

struct SpeakerMemoryStatus: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status", abstract: "List remembered voices or enable/disable automatic voice memory.")
    @Option(help: "Enable or disable learning and matching, preserving saved fingerprints.") var enabled: Bool?
    func run() throws {
        if let enabled { try Config.setVoiceMemoryEnabled(enabled) }
        let memory = try VoiceMemoryStore.shared.read()
        let payload: [String: Any] = ["enabled": Config.voiceMemoryEnabled(), "path": VoiceMemoryStore.shared.url.path,
            "model": memory.model, "profiles": memory.profiles.map {
                ["name": $0.name, "samples": $0.exemplars.count, "recordings": Set($0.exemplars.map(\.recording)).count] as [String: Any]
            }]
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) + Data("\n".utf8))
    }
}

struct SpeakerMemoryForget: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "forget", abstract: "Delete a person's saved voice fingerprint.")
    @Argument var name: String
    func run() throws {
        let removed = try VoiceMemoryStore.shared.update { memory in
            let count = memory.profiles.count
            memory.profiles.removeAll { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            return count - memory.profiles.count
        }
        print(removed == 0 ? "No fingerprint found for \(name)." : "Forgot \(name).")
    }
}

struct SpeakerMemoryLearn: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "learn", abstract: "Learn from a completed recording's verified speaking tiles, without changing its transcript or uploading audio.")
    @Argument var recording: String
    @Option(help: "Explicitly confirm that all remote speech in this recording belongs to this person.") var soleRemoteSpeaker: String?
    func run() throws {
        if let name = soleRemoteSpeaker, SpeakerAttribution.cleanName(name) != name { throw ValidationError("Enter a valid speaker name.") }
        let command = self
        Task {
            do { try await command.learn(); Darwin.exit(0) }
            catch { FileHandle.standardError.write(Data("Speaker memory learning failed: \(error)\n".utf8)); Darwin.exit(1) }
        }
        dispatchMain()
    }

    private func learn() async throws {
        let directory = URL(fileURLWithPath: (recording as NSString).expandingTildeInPath)
        let meta = try SessionMeta.read(from: directory)
        guard let track = meta.tracks.first(where: { $0.source == "system" }), let started = meta.audioStartedAt else {
            throw ValidationError("This recording needs a remote audio track and its start timestamp.")
        }
        let audio = directory.appendingPathComponent(track.file)
        var analysis = try await SpeakerDiarizer.analyze(audio, source: "system", captureVoiceSamples: true)
        let text = (try? String(contentsOf: directory.appendingPathComponent("speaker-observations.jsonl"), encoding: .utf8)) ?? ""
        let observations = try text.split(separator: "\n").map { try JSONDecoder().decode(SpeakerObservation.self, from: Data($0.utf8)) }
        analysis.named_spans = SpeakerAttribution.nameSpans(turns: analysis.turns, observations: observations,
            audioStartedAt: started + Double(track.offsetMs) / 1000, segments: [])
        analysis.voice_identities = SpeakerAttribution.voiceNames(turns: analysis.turns, spans: analysis.named_spans)
        let confirmed = soleRemoteSpeaker.map { name in Dictionary(uniqueKeysWithValues: Set(analysis.turns.map(\.speaker_id)).map { ($0, name) }) } ?? [:]
        let hash = try ElevenLabsEngine.fingerprint(audio)
        let learned = try VoiceMemoryStore.shared.update { $0.learn(analysis, recording: hash, confirmed: confirmed) }
        print("Learned \(learned) voice fingerprint(s). Existing recordings and transcripts were preserved.")
    }
}

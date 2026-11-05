import Darwin
import Foundation

/// Names chosen by the user for a Scribe recording's voices, and the most likely
/// defaults offered for them. The original transcript is never edited: names go
/// into the separate named copy, with `manual` attribution.
enum SpeakerNames {
    struct Row: Hashable, Sendable {
        /// Transcript speaker ID, for example `meeting_1`.
        let speaker: String
        /// "Speaker 1", as the unnamed transcript shows it.
        let label: String
        /// The pre-selected name; nil is Unknown.
        let name: String?
        /// Why that name is pre-selected; nil for Unknown.
        let reason: String?
    }

    struct State: Hashable, Sendable {
        let rows: [Row]
        /// Names the pickers offer, in roster order, then any other suggested name.
        let names: [String]
        /// The named copy names every voice.
        let complete: Bool
    }

    private static func percent(_ value: Double) -> String { "\(Int((value * 100).rounded(.down)))%" }

    private static func reason(_ attribution: String?, _ voice: ElevenLabsTranscripts.SpeakerEvidenceReport?) -> String {
        switch attribution {
        case "manual": return "Chosen by you"
        case "local_microphone_majority": return "Mostly your microphone"
        case "roster_elimination": return "Only participant left"
        case "meeting_timeline": return voice.map { "Speaking tile, \(percent($0.agreement)) agreement" } ?? "Speaking tile"
        default: return "Named copy"
        }
    }

    /// Defaults: the names the named copy already gives (`fixed`, speaker ID to
    /// name and attribution), names assigned in the report, then the strongest
    /// remaining tile evidence, the microphone majority, and the last participant
    /// left. No name is pre-selected twice.
    static func rows(_ speakers: [ElevenLabsTranscripts.SpeakerEvidenceReport], fixed: [String: (name: String, attribution: String?)] = [:],
                     participants: [String], localName: String?) -> [Row] {
        let voices = speakers.filter { $0.provider_speaker_id != nil }
        var chosen: [String: (name: String, reason: String)] = [:]
        func used(_ name: String) -> Bool { chosen.values.contains { $0.name.caseInsensitiveCompare(name) == .orderedSame } }
        for voice in voices {
            if let current = fixed[voice.speaker] { chosen[voice.speaker] = (current.name, reason(current.attribution, voice)) }
        }
        for voice in voices where chosen[voice.speaker] == nil {
            guard let name = voice.name, !used(name) else { continue }
            chosen[voice.speaker] = (name, reason(voice.attribution ?? "meeting_timeline", voice))
        }
        for voice in voices.sorted(by: { $0.agreement * $0.observed_seconds > $1.agreement * $1.observed_seconds })
        where chosen[voice.speaker] == nil {
            guard let name = voice.candidate_name, voice.observed_seconds > 0, !used(name) else { continue }
            chosen[voice.speaker] = (name, reason("meeting_timeline", voice))
        }
        if let localName, !used(localName) {
            func share(_ voice: ElevenLabsTranscripts.SpeakerEvidenceReport) -> Double {
                let local = voice.local_seconds ?? 0, total = local + (voice.remote_seconds ?? 0)
                return total > 0 ? local / total : 0
            }
            if let voice = voices.filter({ chosen[$0.speaker] == nil && share($0) > 0.5 }).max(by: { share($0) < share($1) }) {
                chosen[voice.speaker] = (localName, "Mostly your microphone")
            }
        }
        let open = voices.filter { chosen[$0.speaker] == nil }
        let left = participants.filter { !used($0) }
        if open.count == 1, left.count == 1 { chosen[open[0].speaker] = (left[0], "Only participant left") }
        return voices.map { voice in
            Row(speaker: voice.speaker, label: label(voice.speaker), name: chosen[voice.speaker]?.name, reason: chosen[voice.speaker]?.reason)
        }
    }

    static func label(_ speaker: String) -> String {
        speaker.split(separator: "_").last.flatMap { Int($0) }.map { "Speaker \($0)" } ?? speaker
    }

    /// The naming state of a combined Scribe recording; nil without a combined
    /// Scribe original or a mapping report (Parakeet, separate tracks, unfinished).
    static func state(in directory: URL) -> State? {
        // Older reports lack newer top-level fields; only the speakers are needed.
        struct Report: Decodable { let speakers: [ElevenLabsTranscripts.SpeakerEvidenceReport] }
        let decoder = JSONDecoder()
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("transcript.json")),
              let original = try? decoder.decode(Transcript.self, from: data), original.variant == "elevenlabs_original",
              original.segments.contains(where: { $0.source == "meeting" }),
              let reportData = try? Data(contentsOf: directory.appendingPathComponent("speaker-mapping.json")),
              let report = try? decoder.decode(Report.self, from: reportData) else { return nil }
        let meta = try? SessionMeta.read(from: directory)
        var participants: [String] = []
        for participant in (original.participant_roster ?? meta?.participantRoster)?.participants ?? [] {
            if let name = SpeakerAttribution.cleanName(participant.name),
               !participants.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) { participants.append(name) }
        }
        var speakers = report.speakers
        for index in speakers.indices where speakers[index].accepted && speakers[index].name == nil {
            speakers[index].name = speakers[index].candidate_name
            speakers[index].attribution = "meeting_timeline"
        }
        // Reports written before the inference existed: derive the source
        // seconds from the saved turns and windows, for defaults only.
        if speakers.contains(where: { $0.local_seconds == nil }),
           let analysis = (try? Data(contentsOf: directory.appendingPathComponent("speaker-analysis.json")))
               .flatMap({ try? decoder.decode(SpeakerAnalysis.self, from: $0) }),
           let manifest = (try? Data(contentsOf: directory.appendingPathComponent(MeetingAudio.manifestName)))
               .flatMap({ try? decoder.decode(MeetingAudio.Manifest.self, from: $0) }) {
            for index in speakers.indices {
                let seconds = ElevenLabsTranscripts.sourceSeconds(analysis.turns.filter { $0.speaker_id == speakers[index].speaker }, manifest)
                speakers[index].local_seconds = seconds.local
                speakers[index].remote_seconds = seconds.remote
            }
            if let roster = original.participant_roster ?? meta?.participantRoster {
                ElevenLabsTranscripts.infer(&speakers, roster: roster, localName: meta?.localSpeakerName,
                                            sharedMicrophone: meta?.sharedMicrophone ?? false)
            }
        }
        // A name that differs from a participant only by case uses the roster's spelling.
        func spelled(_ name: String) -> String {
            participants.first { $0.caseInsensitiveCompare(name) == .orderedSame } ?? name
        }
        var fixed: [String: (name: String, attribution: String?)] = [:]
        let named = (try? Data(contentsOf: directory.appendingPathComponent("transcript-named.json")))
            .flatMap { try? decoder.decode(Transcript.self, from: $0) }
        for segment in named?.segments ?? [] where fixed[segment.speaker] == nil {
            if let name = segment.speaker_name { fixed[segment.speaker] = (spelled(name), segment.attribution) }
        }
        let present = Set(original.segments.map(\.speaker))
        let rows = Self.rows(speakers, fixed: fixed, participants: participants, localName: meta?.localSpeakerName)
            .filter { present.contains($0.speaker) }
            .map { Row(speaker: $0.speaker, label: $0.label, name: $0.name.map(spelled), reason: $0.reason) }
        var names = participants
        for name in rows.compactMap(\.name) where !names.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) { names.append(name) }
        return State(rows: rows, names: names, complete: !rows.isEmpty && rows.allSatisfy { fixed[$0.speaker] != nil })
    }

    /// Writes the named copy from the original transcript with `names` (speaker
    /// ID to name), under the lock the speaker commands take. Other voices stay
    /// unnamed, or with `keepingOtherNames` keep the names and attribution the
    /// named copy gave them. A replaced named copy is kept under
    /// `speaker-label-backup-<id>/`, which is returned. Naming nobody removes it.
    @discardableResult
    static func apply(_ names: [String: String], in directory: URL, keepingOtherNames: Bool = false) throws -> URL? {
        let fm = FileManager.default
        let lock = open(directory.appendingPathComponent(".postprocess.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw TranscriptionFailure("Could not lock this recording.") }
        defer { flock(lock, LOCK_UN); close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            throw TranscriptionFailure("This recording is being processed. Try again when it finishes.")
        }
        let url = directory.appendingPathComponent("transcript.json")
        let data = try Data(contentsOf: url)
        let original = try JSONDecoder().decode(Transcript.self, from: data)
        guard original.engine == "elevenlabs", original.variant == "elevenlabs_original" else {
            throw TranscriptionFailure("Only ElevenLabs transcripts get a separate named copy.")
        }
        let speakers = Set(original.segments.map(\.speaker))
        var clean: [String: String] = [:]
        for (speaker, raw) in names {
            guard speakers.contains(speaker), !speaker.hasSuffix("_unknown") else {
                throw TranscriptionFailure("\(label(speaker)) is not a separated voice in this transcript.")
            }
            guard let name = SpeakerAttribution.cleanName(raw) else { throw TranscriptionFailure("Enter a name without line breaks.") }
            clean[speaker] = name
        }
        var named = original
        named.variant = "elevenlabs_named"
        if keepingOtherNames, let data = try? Data(contentsOf: directory.appendingPathComponent("transcript-named.json")) {
            let previous = try JSONDecoder().decode(Transcript.self, from: data)
            guard previous.segments.count == named.segments.count,
                  zip(previous.segments, named.segments).allSatisfy({ $0.speaker == $1.speaker && $0.start_ms == $1.start_ms }) else {
                throw TranscriptionFailure("The named copy does not match the transcript. Regenerate it or name every voice.")
            }
            for index in named.segments.indices where clean[named.segments[index].speaker] == nil {
                named.segments[index].speaker_name = previous.segments[index].speaker_name
                named.segments[index].attribution = previous.segments[index].attribution
            }
        }
        for index in named.segments.indices {
            guard let name = clean[named.segments[index].speaker] else { continue }
            named.segments[index].speaker_name = name
            named.segments[index].attribution = "manual"
        }
        let files = ["transcript-named.json", "transcript-named.md"]
        var backup: URL?
        if files.contains(where: { fm.fileExists(atPath: directory.appendingPathComponent($0).path) }) {
            let saved = directory.appendingPathComponent("speaker-label-backup-" + UUID().uuidString)
            try fm.createDirectory(at: saved, withIntermediateDirectories: false)
            for file in files where fm.fileExists(atPath: directory.appendingPathComponent(file).path) {
                try fm.copyItem(at: directory.appendingPathComponent(file), to: saved.appendingPathComponent(file))
            }
            backup = saved
        }
        guard try Data(contentsOf: url) == data else { throw TranscriptionFailure("The transcript changed while naming speakers.") }
        do {
            if !named.segments.contains(where: { $0.speaker_name != nil }) { try ElevenLabsTranscripts.removeNamedVariant(in: directory) }
            else { try named.write(to: directory, basename: "transcript-named") }
        } catch {
            for file in files {
                let target = directory.appendingPathComponent(file)
                if let saved = backup?.appendingPathComponent(file), fm.fileExists(atPath: saved.path) {
                    try Data(contentsOf: saved).write(to: target, options: .atomic)
                } else if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            }
            throw error
        }
        return backup
    }
}

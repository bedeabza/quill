import CryptoKit
import Foundation

/// User-confirmed people are separate from provider voice IDs and audio sources.
/// This sidecar never changes the original transcript or recorded observations.
struct SpeakerIdentities: Codable, Hashable, Sendable {
    static let filename = "speaker-identities.json"
    struct Person: Codable, Hashable, Sendable {
        let id: String
        let name: String?
        let voices: [String]
    }
    var schema_version = 1
    var transcript_sha256: String = ""
    var people: [Person] = []
    /// Normalized observed label -> explicitly chosen canonical display name.
    var aliases: [String: String] = [:]

    static func key(_ name: String) -> String {
        name.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }

    static func fingerprint(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func read(in directory: URL) -> Self {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(filename)),
              var value = try? JSONDecoder().decode(Self.self, from: data), value.schema_version == 1 else { return Self() }
        // A new diarization may reuse the same voice IDs for different people.
        let original = try? Data(contentsOf: directory.appendingPathComponent("transcript.json"))
        if original.map(fingerprint) != value.transcript_sha256 { value.people = [] }
        return value
    }

    func canonicalName(_ name: String) -> String {
        var current = name, seen: Set<String> = []
        while seen.insert(Self.key(current)).inserted, let next = aliases[Self.key(current)] { current = next }
        return current
    }

    func person(for voice: String) -> Person? { people.first { $0.voices.contains(voice) } }

    /// A roster label is not a unique person ID. Deduplicating labels must never
    /// merge voices: even two people with exactly the same name stay separate.
    func participantNames(_ names: [String]) -> [String] {
        var seen: Set<String> = []
        return names.compactMap(SpeakerAttribution.cleanName).map(canonicalName)
            .filter { seen.insert(Self.key($0)).inserted }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    static let inferredAttributions: Set<String> = ["local_microphone", "local_microphone_majority", "roster_elimination"]

    func resolved(_ transcript: Transcript) -> Transcript {
        var result = transcript
        for index in result.segments.indices {
            let segment = result.segments[index]
            result.segments[index].person_id = nil
            if let person = person(for: segment.speaker) {
                result.segments[index].speaker_name = person.name.map(canonicalName)
                result.segments[index].person_id = person.id
                result.segments[index].attribution = "manual"
            } else if Self.inferredAttributions.contains(segment.attribution ?? "") {
                result.segments[index].speaker_name = nil
                result.segments[index].attribution = "unconfirmed_identity"
            } else if let name = segment.speaker_name {
                result.segments[index].speaker_name = canonicalName(name)
            }
        }
        if var roster = result.participant_roster {
            var participants: [MeetingParticipant] = []
            for participant in roster.participants {
                let name = canonicalName(participant.name)
                if let index = participants.firstIndex(where: { Self.key($0.name) == Self.key(name) }) {
                    participants[index].is_local = participants[index].is_local || participant.is_local
                    participants[index].first_seen = min(participants[index].first_seen, participant.first_seen)
                    participants[index].last_seen = max(participants[index].last_seen, participant.last_seen)
                    participants[index].sources = Array(Set(participants[index].sources + participant.sources)).sorted()
                } else {
                    participants.append(MeetingParticipant(name: name, is_local: participant.is_local,
                        first_seen: participant.first_seen, last_seen: participant.last_seen, sources: participant.sources))
                }
            }
            roster.participants = participants
            result.participant_roster = roster
        }
        return result
    }

    static func make(original: Data, names: [String: String], groups: [String: String],
                     aliases: [String: String], previous: Self) throws -> Self {
        let transcript = try JSONDecoder().decode(Transcript.self, from: original)
        let voices = Set(transcript.segments.map(\.speaker))
        guard Set(groups.keys).isSubset(of: voices) else { throw TranscriptionFailure("The transcript changed. Reopen the speaker editor.") }
        var result = Self(transcript_sha256: fingerprint(original))
        for (alias, raw) in aliases {
            guard let name = SpeakerAttribution.cleanName(raw), SpeakerAttribution.cleanName(alias) != nil else {
                throw TranscriptionFailure("Enter a valid participant name.")
            }
            if key(alias) != key(name) { result.aliases[key(alias)] = name }
        }
        for alias in result.aliases.keys {
            var seen: Set<String> = [alias], current = alias
            while let next = result.aliases[current] {
                current = key(next)
                guard seen.insert(current).inserted else { throw TranscriptionFailure("Participant aliases form a loop. Choose one main name.") }
            }
        }
        let grouped = Dictionary(grouping: voices.sorted()) { groups[$0] ?? previous.person(for: $0)?.id ?? $0 }
        for (group, members) in grouped.sorted(by: { $0.key < $1.key }) {
            let chosen = Set(members.compactMap { names[$0].map(result.canonicalName) })
            guard chosen.count <= 1 else { throw TranscriptionFailure("Linked voices need the same name. Separate them if they are different people.") }
            if chosen.isEmpty && members.count == 1 { continue }
            let id = previous.people.contains(where: { $0.id == group }) ? group : UUID().uuidString
            result.people.append(Person(id: id, name: chosen.first, voices: members))
        }
        return result
    }
}

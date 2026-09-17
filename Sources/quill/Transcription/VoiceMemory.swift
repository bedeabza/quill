import Foundation
import Darwin

struct VoiceSample: Codable, Sendable {
    let speaker_id: String
    let start: Double
    let end: Double
    let embedding: [Float]
}

/// Versioned, local speaker fingerprints. Only contemporaneous UI evidence or
/// an explicit user label can enroll samples. Recognition never trains itself.
struct VoiceMemory: Codable, Sendable {
    static let embeddingModel = "community-1-wespeaker-256-v1"
    var version = 1
    var model = embeddingModel
    var profiles: [Profile] = []

    struct Exemplar: Codable, Sendable {
        let recording: String
        let start: Double
        let embedding: [Float]
    }
    struct Profile: Codable, Sendable {
        let name: String
        var exemplars: [Exemplar]
    }

    static func normalized(_ vector: [Float]) -> [Float]? {
        guard vector.count == 256, vector.allSatisfy(\.isFinite) else { return nil }
        let norm = sqrt(vector.reduce(0.0) { $0 + Double($1) * Double($1) })
        guard norm.isFinite, norm > 0.0001 else { return nil }
        return vector.map { Float(Double($0) / norm) }
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == 256, b.count == 256 else { return -1 }
        return zip(a, b).reduce(0) { $0 + Double($1.0) * Double($1.1) }
    }

    private static func average(_ vectors: [[Float]]) -> [Float]? {
        guard !vectors.isEmpty else { return nil }
        var sum = Array(repeating: Float(0), count: 256)
        for vector in vectors {
            guard let normalized = normalized(vector) else { return nil }
            for index in sum.indices { sum[index] += normalized[index] / Float(vectors.count) }
        }
        return normalized(sum)
    }

    /// Select disjoint, sufficiently long, single-speaker windows. Overlapping
    /// diarizer windows must not count as independent recognition evidence.
    static func cleanSamples(_ samples: [VoiceSample], turns: [SpeakerTurn]) -> [VoiceSample] {
        var ends: [String: Double] = [:]
        return samples.sorted { $0.start < $1.start }.compactMap { sample in
            guard sample.start.isFinite, sample.end.isFinite, sample.start >= 0, sample.end > sample.start,
                  sample.start >= (ends[sample.speaker_id] ?? 0),
                  let vector = normalized(sample.embedding) else { return nil }
            let audible = turns.filter { $0.start < sample.end && $0.end > sample.start }
            guard !audible.isEmpty, audible.allSatisfy({ $0.speaker_id == sample.speaker_id }),
                  duration(audible.map { (max(sample.start, $0.start), min(sample.end, $0.end)) }) >= 3 else { return nil }
            ends[sample.speaker_id] = sample.end
            return VoiceSample(speaker_id: sample.speaker_id, start: sample.start, end: sample.end, embedding: vector)
        }
    }

    private static func duration(_ intervals: [(Double, Double)]) -> Double {
        var end = -Double.infinity, total = 0.0
        for span in intervals.sorted(by: { $0.0 < $1.0 }) {
            total += max(0, span.1 - max(end, span.0)); end = max(end, span.1)
        }
        return total
    }

    private func score(_ sample: VoiceSample, profile: Profile) -> Double {
        let values = profile.exemplars.compactMap { Self.normalized($0.embedding) }
            .map { Self.cosine(sample.embedding, $0) }.sorted(by: >)
        guard values.count >= 3 else { return -1 }
        return (values[0] + values[1]) / 2
    }

    func identities(for analysis: SpeakerAnalysis, roster: ParticipantRoster?, excludingRecording: String? = nil) -> [String: SpeakerIdentity] {
        guard version == 1, model == Self.embeddingModel else { return [:] }
        let samples = Self.cleanSamples(analysis.voice_samples ?? [], turns: analysis.turns)
        var result: [String: SpeakerIdentity] = [:]
        for (id, samples) in Dictionary(grouping: samples, by: \.speaker_id) where samples.count >= 9 {
            guard analysis.voice_identities?[id] == nil else { continue }
            var winners: [String] = []
            var conflictingVoice = false
            // Pool three disjoint windows per vote. Single short-utterance
            // embeddings vary with phonetics and are not reliable fingerprints.
            let voteCount = samples.count / 3
            for index in 0..<voteCount {
                let group = Array(samples[(index * 3)..<(index * 3 + 3)])
                guard let vector = Self.average(group.map(\.embedding)) else { continue }
                let sample = VoiceSample(speaker_id: id, start: group[0].start, end: group[2].end, embedding: vector)
                let ranked = profiles.map { profile in
                    (profile.name, score(sample, profile: Profile(name: profile.name, exemplars: profile.exemplars.filter { $0.recording != excludingRecording })))
                }.sorted { $0.1 > $1.1 }
                guard let best = ranked.first else { continue }
                if best.1 < 0.65 || (ranked.count > 1 && best.1 - ranked[1].1 < 0.12) {
                    conflictingVoice = true
                }
                guard best.1 >= 0.80, ranked.count == 1 || best.1 - ranked[1].1 >= 0.12 else { continue }
                winners.append(best.0)
            }
            guard !conflictingVoice, winners.count >= 3, Double(winners.count) / Double(voteCount) >= 0.8,
                  Set(winners.map { $0.lowercased() }).count == 1, let name = winners.first else { continue }
            // Also require a stronger match from the full voice aggregate.
            // This tolerates a mildly noisy individual vote without relying on it.
            guard let aggregate = Self.average(samples.map(\.embedding)) else { continue }
            let pooled = VoiceSample(speaker_id: id, start: 0, end: 0, embedding: aggregate)
            let pooledScores = profiles.map { profile in
                (profile.name, score(pooled, profile: Profile(name: profile.name,
                    exemplars: profile.exemplars.filter { $0.recording != excludingRecording })))
            }.sorted { $0.1 > $1.1 }
            guard let strongest = pooledScores.first, strongest.0.caseInsensitiveCompare(name) == .orderedSame,
                  strongest.1 >= 0.90, pooledScores.count == 1 || strongest.1 - pooledScores[1].1 >= 0.15 else { continue }
            let turns = analysis.turns.filter { $0.speaker_id == id }
            // Any current conflicting speaker evidence defeats global memory.
            guard !analysis.named_spans.contains(where: { span in
                span.identity.name.caseInsensitiveCompare(name) != .orderedSame && turns.contains {
                    min($0.end, span.end) - max($0.start, span.start) >= 0.2
                }
            }) else { continue }
            if let roster {
                let remoteNames = roster.participants.filter { !$0.is_local }.map { $0.name.lowercased() }
                if !remoteNames.isEmpty && !remoteNames.contains(name.lowercased()) { continue }
                if roster.participants.contains(where: { $0.is_local && $0.name.caseInsensitiveCompare(name) == .orderedSame }) { continue }
            }
            result[id] = SpeakerIdentity(name: name, source: "voice_fingerprint", evidence_count: winners.count)
        }
        return result
    }

    /// Enrollment uses the actual named parts of a voice, not the entire
    /// acoustic cluster. Captions and fingerprint-derived names are excluded.
    mutating func learn(_ analysis: SpeakerAnalysis, recording: String, confirmed: [String: String] = [:]) -> Int {
        guard version == 1, model == Self.embeddingModel else { return 0 }
        let samples = Self.cleanSamples(analysis.voice_samples ?? [], turns: analysis.turns)
        var byName: [String: [VoiceSample]] = [:]
        for sample in samples {
            if let name = confirmed[sample.speaker_id], SpeakerAttribution.cleanName(name) == name {
                byName[name, default: []].append(sample)
                continue
            }
            guard let identity = analysis.voice_identities?[sample.speaker_id], identity.source == "meeting_voice" else { continue }
            let spans = analysis.named_spans.filter { $0.start < sample.end && $0.end > sample.start }
            guard spans.allSatisfy({ $0.identity.name.caseInsensitiveCompare(identity.name) == .orderedSame }) else { continue }
            let trusted = spans.filter { ["meeting_tile", "zoom_border"].contains($0.identity.source) && $0.identity.evidence_count >= 3 }
            let coverage = Self.duration(trusted.map { (max(sample.start, $0.start), min(sample.end, $0.end)) })
            let speech = Self.duration(analysis.turns.filter { $0.speaker_id == sample.speaker_id && $0.start < sample.end && $0.end > sample.start }
                .map { (max(sample.start, $0.start), min(sample.end, $0.end)) })
            guard coverage >= 3, coverage >= speech * 0.6 else { continue }
            byName[identity.name, default: []].append(sample)
        }
        var learned = 0
        for (name, candidates) in byName.sorted(by: { $0.key < $1.key }) {
            guard candidates.count >= 9, let center = Self.average(candidates.map(\.embedding)) else { continue }
            // Reject outliers, then build independent prototypes from disjoint
            // groups. A coherent majority is required before saving a person.
            let coherent = candidates.filter { Self.cosine(center, $0.embedding) >= 0.65 }
            guard coherent.count >= 9, Double(coherent.count) / Double(candidates.count) >= 0.6 else { continue }
            let count = min(4, coherent.count / 3)
            let selected: [VoiceSample] = (0..<count).compactMap { index in
                let group = Array(coherent[(index * coherent.count / count)..<((index + 1) * coherent.count / count)])
                guard let vector = Self.average(group.map(\.embedding)), let first = group.first, let last = group.last else { return nil }
                return VoiceSample(speaker_id: first.speaker_id, start: first.start, end: last.end, embedding: vector)
            }
            guard selected.count == count,
                  selected.allSatisfy({ a in selected.allSatisfy { Self.cosine(a.embedding, $0.embedding) >= 0.80 } }) else { continue }
            let index = profiles.firstIndex { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            if let index {
                guard !profiles[index].exemplars.contains(where: { $0.recording == recording }),
                      selected.allSatisfy({ score($0, profile: profiles[index]) >= 0.80 }) else { continue }
            }
            let exemplars = selected.map { Exemplar(recording: recording, start: $0.start, embedding: $0.embedding) }
            if let index { profiles[index].exemplars = Array((profiles[index].exemplars + exemplars).suffix(24)) }
            else { profiles.append(Profile(name: name, exemplars: exemplars)) }
            learned += 1
        }
        return learned
    }
}

struct VoiceMemoryStore: Sendable {
    static let shared = VoiceMemoryStore(url: FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Quill/SpeakerMemory/profiles.json"))
    let url: URL

    func read() throws -> VoiceMemory {
        guard FileManager.default.fileExists(atPath: url.path) else { return VoiceMemory() }
        let memory = try JSONDecoder().decode(VoiceMemory.self, from: Data(contentsOf: url))
        guard memory.version == 1, memory.model == VoiceMemory.embeddingModel else {
            throw TranscriptionFailure("Speaker fingerprint store uses an incompatible model or version.")
        }
        return memory
    }

    func update<T>(_ body: (inout VoiceMemory) throws -> T) throws -> T {
        let fm = FileManager.default, directory = url.deletingLastPathComponent()
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let descriptor = open(directory.appendingPathComponent(".lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw TranscriptionFailure("Could not open speaker fingerprint lock.") }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw TranscriptionFailure("Speaker fingerprints are being updated by another process.") }
        defer { flock(descriptor, LOCK_UN) }
        var memory = try read()
        let result = try body(&memory)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(memory).write(to: url, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return result
    }

    func apply(to analysis: inout SpeakerAnalysis, recording: String, roster: ParticipantRoster?, learn: Bool) throws {
        // Resolve before enrollment, so the same call cannot serve as its own
        // evidence for a cross-meeting match.
        let snapshot = analysis
        func resolve(_ memory: inout VoiceMemory) -> [String: SpeakerIdentity] {
            let matches = memory.identities(for: snapshot, roster: roster, excludingRecording: recording)
            if learn { _ = memory.learn(snapshot, recording: recording) }
            return matches
        }
        let matches: [String: SpeakerIdentity]
        if learn { matches = try update(resolve) }
        else { var memory = try read(); matches = resolve(&memory) }
        analysis.voice_identities = matches.merging(analysis.voice_identities ?? [:]) { _, current in current }
    }
}

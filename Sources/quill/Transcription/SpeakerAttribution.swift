import Foundation
import CryptoKit

struct SpeakerTurn: Codable, Sendable {
    let speaker_id: String
    let start: Double
    let end: Double
}

/// One contemporaneous UI observation. Empty/multiple names are meaningful:
/// they never authorize attributing speech to a single person.
struct SpeakerObservation: Codable, Sendable {
    let observed_at: Double
    let meeting_id: String
    let names: [String]
    var source = "accessibility_active_speaker"
    var text: String? = nil
    var is_local: Bool? = nil
}

struct SpeakerIdentity: Codable, Equatable, Sendable {
    let name: String
    let source: String
    let evidence_count: Int
}

struct NamedSpeakerSpan: Codable, Sendable {
    let start: Double
    let end: Double
    let identity: SpeakerIdentity
}

enum SpeakerAttribution {
    static func cleanName(_ value: String?) -> String? {
        guard let value else { return nil }
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 100,
              !name.contains(where: { $0.isNewline || $0.asciiValue.map { $0 < 32 } == true }),
              !["you", "me", "unknown", "speaker", "someone", "them"].contains(name.lowercased()),
              !name.lowercased().hasSuffix("(you)") else { return nil }
        return name
    }

    static func isLocalName(_ name: String, localName: String?) -> Bool {
        guard let localName = cleanName(localName) else { return false }
        return name.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(localName) == .orderedSame
    }

    /// Require sustained, unambiguous observations in the middle of speech.
    /// UI indicators lag audio at turn boundaries, so discard those samples.
    static func names(turns: [SpeakerTurn], observations: [SpeakerObservation], audioStartedAt: Double) -> [String: SpeakerIdentity] {
        var votes: [String: [String: [Double]]] = [:]
        for sample in observations where sample.source == "accessibility_active_speaker" {
            guard sample.names.count == 1, let name = cleanName(sample.names.first) else { continue }
            let time = sample.observed_at - audioStartedAt
            let candidates = Set(turns.filter { $0.start + 0.6 <= time && time <= $0.end - 0.6 }.map(\.speaker_id))
            let audible = Set(turns.filter { $0.start <= time && time <= $0.end }.map(\.speaker_id))
            guard candidates.count == 1, audible.count == 1, let id = candidates.first else { continue }
            votes[id, default: [:]][name, default: []].append(time)
        }
        var matches: [String: SpeakerIdentity] = [:]
        for (id, counts) in votes {
            let ranked = counts.sorted { $0.value.count > $1.value.count }
            guard let best = ranked.first else { continue }
            let times = Set(best.value)
            let total = counts.values.reduce(0) { $0 + Set($1).count }
            guard times.count >= 3, (times.max() ?? 0) - (times.min() ?? 0) >= 3,
                  Double(times.count) / Double(total) >= 0.9 else { continue }
            matches[id] = SpeakerIdentity(name: best.key, source: "meeting_ui", evidence_count: times.count)
        }
        // Reused display names and split clusters require a correction, not a guess.
        let byName = Dictionary(grouping: matches.keys, by: { matches[$0]!.name.lowercased() })
        return matches.filter { !$0.value.name.isEmpty && byName[$0.value.name.lowercased()]?.count == 1 }
    }

    static func nameSpans(turns: [SpeakerTurn], observations: [SpeakerObservation], audioStartedAt: Double,
                          segments: [TranscriptSegment]) -> [NamedSpeakerSpan] {
        var result = captionSpans(observations: observations, audioStartedAt: audioStartedAt, segments: segments)
        result += tileSpans(observations: observations, audioStartedAt: audioStartedAt)
        for turn in turns {
            let local = observations.filter { $0.source == "accessibility_active_speaker" &&
                $0.observed_at - audioStartedAt >= turn.start && $0.observed_at - audioStartedAt <= turn.end }
            guard let identity = names(turns: turns, observations: local, audioStartedAt: audioStartedAt)[turn.speaker_id] else { continue }
            let times = local.filter { $0.names == [identity.name] }.map { $0.observed_at - audioStartedAt }
            guard let first = times.min(), let last = times.max() else { continue }
            result.append(NamedSpeakerSpan(start: first, end: last, identity: identity))
        }
        return result
    }

    /// Tile state is independent of caption language. Keep short, observed
    /// runs only; unknown/multiple speakers and missing samples end the run.
    static func tileSpans(observations: [SpeakerObservation], audioStartedAt: Double) -> [NamedSpeakerSpan] {
        let samples = observations.filter { ["meeting_tile", "zoom_border"].contains($0.source) && $0.is_local != true }.sorted { $0.observed_at < $1.observed_at }
        var result: [NamedSpeakerSpan] = []
        var name: String?
        var meetingID: String?
        var source = "meeting_tile"
        var first = 0.0, last = 0.0
        var count = 0
        func flush() {
            if let name, count >= 3, last - first >= 0.4 {
                let start = max(0, first - audioStartedAt - 0.125), end = last - audioStartedAt + 0.125
                guard end > start else { return }
                result.append(NamedSpeakerSpan(start: start, end: end,
                    identity: SpeakerIdentity(name: name, source: source, evidence_count: count)))
            }
        }
        for sample in samples {
            let current = sample.names.count == 1 ? cleanName(sample.names.first) : nil
            if current != name || sample.meeting_id != meetingID || sample.source != source || sample.observed_at - last > 0.75 {
                flush()
                name = current
                meetingID = sample.meeting_id
                source = sample.source
                first = sample.observed_at
                count = 0
            }
            if sample.observed_at > last { count += 1 }
            last = sample.observed_at
        }
        flush()
        return result
    }

    private static func tokens(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    /// Caption timestamps are arrival times, not speech times. Align unique
    /// five-word phrases to ASR near the observation. Name only the matched
    /// speech; an acoustic cluster can contain multiple actual people.
    private static func captionSpans(observations: [SpeakerObservation], audioStartedAt: Double,
                                     segments: [TranscriptSegment]) -> [NamedSpeakerSpan] {
        let words = segments.flatMap(\.words).flatMap { word in
            tokens(word.text).map { TranscriptWord(start: word.start, end: word.end, text: $0) }
        }
        guard words.count >= 5 else { return [] }
        var phrases: [String: [Int]] = [:]
        for index in 0...(words.count - 5) {
            let phrase = words[index..<(index + 5)].map(\.text).joined(separator: " ")
            phrases[phrase, default: []].append(index)
        }
        var evidence: [String: Set<Int>] = [:]
        for sample in observations where sample.source == "meeting_caption" && sample.is_local != true {
            guard sample.names.count == 1, let name = cleanName(sample.names.first), let text = sample.text else { continue }
            let caption = tokens(text)
            guard caption.count >= 5 else { continue }
            let time = sample.observed_at - audioStartedAt
            for index in 0...(caption.count - 5) {
                let phrase = caption[index..<(index + 5)].joined(separator: " ")
                let positions = (phrases[phrase] ?? []).filter { words[$0].start >= time - 25 && words[$0 + 4].end <= time + 2 }
                guard positions.count == 1, let start = positions.first else { continue }
                for position in start..<(start + 5) {
                    evidence[name, default: []].insert(position)
                }
            }
        }
        var matches: [NamedSpeakerSpan] = []
        for (name, positions) in evidence {
            let identity = SpeakerIdentity(name: name, source: "meeting_caption", evidence_count: positions.count)
            for position in positions.sorted() {
                matches.append(NamedSpeakerSpan(start: words[position].start, end: words[position].end, identity: identity))
            }
        }
        return matches
    }

    static func namedSpeakerID(_ identity: SpeakerIdentity, source: String) -> String {
        let hash = SHA256.hash(data: Data(identity.name.lowercased().utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return "\(source)_name_\(hash)"
    }

    private static func coveredDuration(_ intervals: [(Double, Double)]) -> Double {
        var total = 0.0
        var lastEnd = -Double.infinity
        for (start, end) in intervals.sorted(by: { $0.0 < $1.0 }) where end > start {
            total += max(0, end - max(start, lastEnd))
            lastEnd = max(lastEnd, end)
        }
        return total
    }

    private static func identity(start: Double, end: Double, spans: [NamedSpeakerSpan]) -> SpeakerIdentity? {
        guard end > start else { return nil }
        let overlapping = spans.filter { $0.start < end && $0.end > start }
        let exact = overlapping.filter { ["meeting_caption", "meeting_tile", "zoom_border"].contains($0.identity.source) }
        let candidates = exact.isEmpty ? overlapping : exact
        let grouped = Dictionary(grouping: candidates, by: { $0.identity.name.lowercased() })
        let coverage = grouped.mapValues { coveredDuration($0.map { (max(start, $0.start), min(end, $0.end)) }) }
        guard let best = coverage.max(by: { $0.value < $1.value }), best.value >= (end - start) * 0.6,
              coverage.filter({ $0.key != best.key }).allSatisfy({ $0.value < min(0.2, (end - start) * 0.2) }) else { return nil }
        return grouped[best.key]?.first?.identity
    }

    /// Learn a recording-local name for a voice from sustained speaking tiles,
    /// never from captions or a participant roster. A voice can split into
    /// several clusters, but a cluster with competing identities stays unnamed.
    static func voiceNames(turns: [SpeakerTurn], spans: [NamedSpeakerSpan]) -> [String: SpeakerIdentity] {
        let trusted = spans.filter {
            ["meeting_tile", "zoom_border"].contains($0.identity.source) && $0.identity.evidence_count >= 3
                && $0.start.isFinite && $0.end.isFinite && $0.end > $0.start
        }
        struct Evidence {
            var intervals: [(Double, Double)] = []
            var turns: Set<Int> = []
            var spans: Set<Int> = []
            var name = ""
        }
        var votes: [String: [String: Evidence]] = [:]
        var voiceIntervals: [String: [(Double, Double)]] = [:]
        for (turnIndex, turn) in turns.enumerated() where turn.start.isFinite && turn.end.isFinite && turn.end > turn.start {
            voiceIntervals[turn.speaker_id, default: []].append((turn.start, turn.end))
            for (spanIndex, span) in trusted.enumerated() {
                let start = max(turn.start + 0.3, span.start), end = min(turn.end - 0.3, span.end)
                guard end - start >= 0.2,
                      !turns.contains(where: { $0.speaker_id != turn.speaker_id && $0.start < end && $0.end > start }),
                      !trusted.contains(where: { $0.identity.name.caseInsensitiveCompare(span.identity.name) != .orderedSame
                          && $0.start < end && $0.end > start }) else { continue }
                let key = span.identity.name.lowercased()
                var evidence = votes[turn.speaker_id, default: [:]][key] ?? Evidence()
                evidence.name = span.identity.name
                evidence.intervals.append((start, end))
                evidence.turns.insert(turnIndex)
                evidence.spans.insert(spanIndex)
                votes[turn.speaker_id, default: [:]][key] = evidence
            }
        }
        var result: [String: SpeakerIdentity] = [:]
        for (id, names) in votes {
            let durations = names.mapValues { coveredDuration($0.intervals) }
            guard let best = durations.max(by: { $0.value < $1.value }), let evidence = names[best.key],
                  best.value >= 10, evidence.turns.count >= 2, evidence.spans.count >= 2,
                  best.value >= coveredDuration(voiceIntervals[id] ?? []) * 0.35,
                  best.value >= durations.values.reduce(0, +) * 0.95,
                  durations.filter({ $0.key != best.key }).allSatisfy({ $0.value < 2 }) else { continue }
            result[id] = SpeakerIdentity(name: evidence.name, source: "meeting_voice", evidence_count: evidence.spans.count)
        }
        return result
    }

    static func resolvedIdentity(start: Double, end: Double, turns: [SpeakerTurn], spans: [NamedSpeakerSpan],
                                 voiceNames: [String: SpeakerIdentity]) -> SpeakerIdentity? {
        guard start.isFinite, end.isFinite, start >= 0, end >= start else { return nil }
        // Scribe can give punctuation/short words a zero-length timestamp.
        // Use a tiny decision window without changing the transcript timestamp.
        let decisionEnd = max(end, start + 0.02)
        if let exact = identity(start: start, end: decisionEnd, spans: spans) { return exact }
        var learned: SpeakerIdentity?
        if let id = speaker(start: start, end: decisionEnd, turns: turns), let name = voiceNames[id] {
            learned = name
        } else {
            // Some ASR word intervals include silence. Resolve those only when
            // every audible cluster has the same independently verified name.
            let audible = turns.filter { min(decisionEnd, $0.end) - max(start, $0.start) > 0.02 }
            let ids = Set(audible.map(\.speaker_id))
            let names = ids.compactMap { voiceNames[$0] }
            if decisionEnd - start <= 30, !ids.isEmpty, names.count == ids.count,
               Set(names.map { $0.name.lowercased() }).count == 1,
               coveredDuration(audible.map { (max(start, $0.start), min(decisionEnd, $0.end)) }) >= min(0.2, (decisionEnd - start) * 0.6) {
                learned = names.first
            }
        }
        func conflicts(_ name: String) -> Bool {
            spans.contains { $0.identity.name.caseInsensitiveCompare(name) != .orderedSame
                && min(decisionEnd, $0.end) - max(start, $0.start) >= min(0.2, (decisionEnd - start) * 0.2) }
        }
        if let learned, !conflicts(learned.name) { return learned }
        // Very short replies can fall just before a delayed Teams border and
        // below acoustic VAD thresholds. Use a bounded edge of a sustained tile,
        // only when nearby UI names and audible voices are unambiguous.
        guard decisionEnd - start <= 1.5 else { return nil }
        let nearby = spans.filter { ["meeting_tile", "zoom_border"].contains($0.identity.source)
            && $0.identity.evidence_count >= 3 && $0.end - $0.start >= 0.4
            && $0.start <= min(decisionEnd + 0.5, start + 0.75) && $0.end >= start - 0.125 }
        let audible = Set(turns.filter { min(decisionEnd, $0.end) > max(start, $0.start) }.map(\.speaker_id))
        guard audible.count <= 1, Set(nearby.map { $0.identity.name.lowercased() }).count == 1,
              let nearest = nearby.first?.identity, !conflicts(nearest.name) else { return nil }
        return SpeakerIdentity(name: nearest.name, source: "meeting_tile_edge", evidence_count: nearest.evidence_count)
    }

    static func speaker(start: Double, end: Double, turns: [SpeakerTurn]) -> String? {
        guard start.isFinite, end.isFinite, end > start else { return nil }
        var durations: [String: Double] = [:]
        for turn in turns where turn.end > start && turn.start < end {
            durations[turn.speaker_id, default: 0] += max(0, min(end, turn.end) - max(start, turn.start))
        }
        let ranked = durations.sorted { $0.value > $1.value }
        if let best = ranked.first, best.value / (end - start) >= 0.6,
           ranked.dropFirst().allSatisfy({ $0.value / (end - start) < 0.2 }) { return best.key }
        // Diarization often trims the start/end of a syllable. Fill only a
        // bounded edge with one nearby voice, never an overlap or voice change.
        guard end - start <= 1.5 else { return nil }
        let nearby = Set(turns.filter { $0.end >= start - 0.6 && $0.start <= end + 0.6 }.map(\.speaker_id))
        return nearby.count == 1 ? nearby.first : nil
    }

    static func align(_ segments: [TranscriptSegment], turns: [SpeakerTurn], source: String,
                      offset: Double, namedSpans: [NamedSpeakerSpan],
                      voiceIdentities: [String: SpeakerIdentity]? = nil) -> [Transcript.Segment] {
        var result: [Transcript.Segment] = []
        let learned = voiceIdentities ?? voiceNames(turns: turns, spans: namedSpans)
        for segment in segments {
            // Without word timings, only label the whole segment when every
            // audible turn agrees. Never assign a mixed sentence to its majority.
            if segment.words.isEmpty {
                let ids = Set(turns.filter { $0.end > segment.start && $0.start < segment.end }.map(\.speaker_id))
                let id = ids.count == 1 ? speaker(start: segment.start, end: segment.end, turns: turns) : nil
                let identity = id.flatMap { learned[$0] }.flatMap { _ in
                    resolvedIdentity(start: segment.start, end: segment.end, turns: turns, spans: namedSpans, voiceNames: learned)
                }
                let fallback = id.flatMap { learned[$0] == nil ? $0 : nil }
                result.append(render(segment.start, segment.end, segment.text,
                                     identity.map { namedSpeakerID($0, source: source) } ?? fallback, source, offset, identity))
                continue
            }
            var words: [TranscriptWord] = []
            var previous: String?
            var previousIdentity: SpeakerIdentity?
            func flush() {
                guard let first = words.first, let last = words.last else { return }
                result.append(render(first.start, last.end, words.map(\.text).joined(separator: " "), previous, source, offset, previousIdentity))
                words = []
            }
            for word in segment.words {
                let identity = resolvedIdentity(start: word.start, end: word.end, turns: turns, spans: namedSpans, voiceNames: learned)
                let acoustic = speaker(start: word.start, end: word.end, turns: turns)
                // A known voice vetoed by conflicting evidence is uncertain,
                // not a newly anonymous "Speaker 1" identity.
                let fallback = acoustic.flatMap { learned[$0] == nil ? $0 : nil }
                let id = identity.map { namedSpeakerID($0, source: source) } ?? fallback
                if !words.isEmpty && id != previous { flush(); previousIdentity = nil }
                previous = id
                if previousIdentity?.source != "meeting_voice",
                   previousIdentity?.source != "meeting_tile_edge" || identity?.source == "meeting_voice" { previousIdentity = identity }
                words.append(word)
            }
            flush()
        }
        return result
    }

    private static func render(_ start: Double, _ end: Double, _ text: String, _ id: String?,
                               _ source: String, _ offset: Double, _ identity: SpeakerIdentity?) -> Transcript.Segment {
        return Transcript.Segment(speaker: id ?? "\(source)_unknown", start_ms: Int((start + offset) * 1000),
                                  end_ms: Int((end + offset) * 1000), text: text, source: source,
                                  speaker_name: identity?.name, attribution: identity?.source ?? (id == nil ? "unknown" : "diarization"))
    }
}

import Foundation

/// Maps provider diarization to recorded active-speaker evidence. No local
/// speaker model, voice memory, roster inference or text cleanup is used.
enum ElevenLabsTranscripts {
    static let threshold = 0.95

    struct TrackResult {
        let track: SessionMeta.Track
        let segments: [TranscriptSegment]
        var meetingAudio: MeetingAudio.Manifest? = nil
    }

    struct SpeakerEvidenceReport: Codable {
        let speaker: String
        let provider_speaker_id: String?
        let candidate_name: String?
        let agreement: Double
        let observed_seconds: Double
        let speech_seconds: Double
        let observed_fraction: Double
        let ambiguous_seconds: Double
        let accepted: Bool
    }

    struct MappingReport: Codable {
        var threshold = ElevenLabsTranscripts.threshold
        var rule = "Every remote speaker needs >=95% agreement by observed speech duration. Missing evidence fails; unobserved speech is excluded from the denominator."
        let accepted: Bool
        let speakers: [SpeakerEvidenceReport]
    }

    struct Output {
        let original: Transcript
        let named: Transcript?
        let report: MappingReport
        let analysis: SpeakerAnalysis

        func write(to directory: URL) throws {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            // Publish the canonical JSON last: it is the queue's completion marker.
            try encoder.encode(report).write(to: directory.appendingPathComponent("speaker-mapping.json"), options: .atomic)
            try encoder.encode(analysis).write(to: directory.appendingPathComponent("speaker-analysis.json"), options: .atomic)
            if let named { try named.write(to: directory, basename: "transcript-named") }
            else { try removeNamedVariant(in: directory) }
            try original.write(to: directory)
        }
    }

    static func removeNamedVariant(in directory: URL) throws {
        for name in ["transcript-named.json", "transcript-named.md"] {
            let url = directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
    }

    private struct Interval {
        let start: Double
        let end: Double
    }

    private static func union(_ intervals: [Interval]) -> [Interval] {
        var result: [Interval] = []
        for interval in intervals.sorted(by: { $0.start < $1.start }) where interval.end > interval.start {
            if let last = result.last, interval.start <= last.end {
                result[result.count - 1] = Interval(start: last.start, end: max(last.end, interval.end))
            } else { result.append(interval) }
        }
        return result
    }

    private static func timelineSpans(_ observations: [SpeakerObservation], origin: Double,
                                      meetingAudio: MeetingAudio.Manifest? = nil, localName: String? = nil,
                                      sharedMicrophone: Bool = false) -> [NamedSpeakerSpan] {
        let samples = observations.flatMap { sample -> [SpeakerObservation] in
            guard meetingAudio != nil, !sharedMicrophone, let local = sample.local_names, !local.isEmpty else { return [sample] }
            return [sample, .init(observed_at: sample.observed_at, meeting_id: sample.meeting_id,
                names: local, source: sample.source, is_local: true)]
        }
        let activity = samples.filter {
            ["meeting_tile", "zoom_border", "accessibility_active_speaker"].contains($0.source)
                && $0.observed_at.isFinite
        }
        // Bound each snapshot to one 250ms sampling window. Do not bridge UI
        // gaps or discard short contradictory observations before the 95% vote.
        // Duplicate/source overlaps are unioned by the duration calculation.
        return activity.flatMap { sample -> [NamedSpeakerSpan] in
            let time = sample.observed_at - origin
            guard time + 0.125 > 0 else { return [] }
            return sample.names.compactMap { raw -> NamedSpeakerSpan? in
                guard let name = SpeakerAttribution.cleanName(raw) else { return nil }
                let local = sample.is_local == true || SpeakerAttribution.isLocalName(name, localName: localName)
                guard meetingAudio != nil || !local, !local || !sharedMicrophone else { return nil }
                return NamedSpeakerSpan(start: max(0, time - 0.125), end: time + 0.125,
                    identity: .init(name: name, source: sample.source, evidence_count: 1))
            }.flatMap { span -> [NamedSpeakerSpan] in
                guard let meetingAudio else { return [span] }
                let local = sample.is_local == true || SpeakerAttribution.isLocalName(span.identity.name, localName: localName)
                let windows = local ? meetingAudio.local_windows : meetingAudio.remote_windows
                // Sorted disjoint source windows: binary search avoids scanning
                // a full hour's envelope for every 250ms UI observation.
                var low = 0, high = windows.count
                while low < high {
                    let middle = (low + high) / 2
                    if windows[middle].end <= span.start { low = middle + 1 } else { high = middle }
                }
                var clipped: [NamedSpeakerSpan] = []
                while low < windows.count, windows[low].start < span.end {
                    clipped.append(.init(start: max(span.start, windows[low].start), end: min(span.end, windows[low].end), identity: span.identity))
                    low += 1
                }
                return clipped
            }
        }
    }

    static func build(meta: SessionMeta, tracks: [TrackResult], roster: ParticipantRoster,
                      observations: [SpeakerObservation], createdAt: String = ISO8601DateFormatter().string(from: Date())) -> Output {
        var merged: [Transcript.Segment] = []
        var analysis = SpeakerAnalysis(model: "scribe_v2", turns: [], names: [:])
        var reports: [SpeakerEvidenceReport] = []
        var statuses: [String: String] = [:]
        var nextSpeaker = 1
        for result in tracks {
            let source = result.track.source
            let offset = Double(result.track.offsetMs) / 1000
            var ids: [String: String] = [:]
            var speech: [String: [Interval]] = [:]
            var providerIDs: [String: String] = [:]
            for segment in result.segments {
                let id: String
                if let provider = segment.speakerID, !provider.isEmpty {
                    if ids[provider] == nil {
                        ids[provider] = "\(source)_\(nextSpeaker)"
                        nextSpeaker += 1
                    }
                    id = ids[provider]!
                    providerIDs[id] = provider
                } else { id = "\(source)_unknown" }
                merged.append(.init(speaker: id, start_ms: Int((segment.start + offset) * 1000),
                    end_ms: Int((segment.end + offset) * 1000), text: segment.text, source: source,
                    attribution: "elevenlabs", provider_speaker_id: segment.speakerID))
                // Silence inside a sentence must not vote for any name.
                let intervals = segment.words.isEmpty
                    ? [Interval(start: segment.start, end: segment.end)]
                    : segment.words.map { Interval(start: $0.start, end: $0.end) }
                speech[id, default: []] += intervals
            }
            speech = speech.mapValues(union)
            let turns = speech.flatMap { id, intervals in intervals.map { SpeakerTurn(speaker_id: id, start: $0.start, end: $0.end) } }
            analysis.turns += turns.map { SpeakerTurn(speaker_id: $0.speaker_id, start: $0.start + offset, end: $0.end + offset) }
            statuses[source] = result.segments.isEmpty ? "no_speech_detected" : "elevenlabs"
            guard source == "system" || source == "meeting" else { continue }
            let spans: [NamedSpeakerSpan]
            if let started = meta.audioStartedAt {
                spans = timelineSpans(observations, origin: started + offset, meetingAudio: result.meetingAudio,
                                      localName: meta.localSpeakerName, sharedMicrophone: meta.sharedMicrophone)
            } else { spans = [] }
            analysis.named_spans += spans.map { NamedSpeakerSpan(start: $0.start + offset, end: $0.end + offset, identity: $0.identity) }
            for id in speech.keys.sorted() {
                let own = speech[id]!
                let competing = speech.filter { $0.key != id }.flatMap(\.value)
                var observed = 0.0, ambiguous = 0.0
                var votes: [String: Double] = [:]
                var displayNames: [String: String] = [:]
                for interval in own {
                    let relevant = spans.filter { $0.start < interval.end && $0.end > interval.start }
                    let other = competing.filter { $0.start < interval.end && $0.end > interval.start }
                    // Partition time so duplicate observations never multiply votes,
                    // and conflicting names/overlapping voices count as ambiguity.
                    let cuts = Set([interval.start, interval.end]
                        + relevant.flatMap { [max(interval.start, $0.start), min(interval.end, $0.end)] }
                        + other.flatMap { [max(interval.start, $0.start), min(interval.end, $0.end)] }).sorted()
                    for (start, end) in zip(cuts, cuts.dropFirst()) where end > start {
                        let active = relevant.filter { $0.start < end && $0.end > start }
                        guard !active.isEmpty else { continue }
                        let duration = end - start
                        observed += duration
                        let names = Set(active.map { $0.identity.name.lowercased() })
                        guard names.count == 1, !other.contains(where: { $0.start < end && $0.end > start }),
                              let identity = active.first?.identity else { ambiguous += duration; continue }
                        let key = identity.name.lowercased()
                        votes[key, default: 0] += duration
                        displayNames[key] = identity.name
                    }
                }
                let best = votes.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.first
                let agreement = observed > 0 ? (best?.value ?? 0) / observed : 0
                let duration = own.reduce(0) { $0 + $1.end - $1.start }
                let name = best.flatMap { displayNames[$0.key] }
                let accepted = providerIDs[id] != nil && name != nil && observed > 0 && agreement + 1e-10 >= threshold
                reports.append(.init(speaker: id, provider_speaker_id: providerIDs[id], candidate_name: name,
                    agreement: agreement, observed_seconds: observed, speech_seconds: duration,
                    observed_fraction: duration > 0 ? observed / duration : 0, ambiguous_seconds: ambiguous, accepted: accepted))
            }
        }
        merged.sort { $0.start_ms < $1.start_ms }
        analysis.turns.sort { $0.start < $1.start }
        var report = MappingReport(accepted: !reports.isEmpty && reports.allSatisfy(\.accepted), speakers: reports)
        if tracks.contains(where: { $0.track.source == "meeting" }) {
            report.rule = "Every speaker in the combined meeting recording needs >=95% agreement by observed speech duration. Only clear matching-source audio windows may vote. Missing evidence fails; unobserved speech is excluded from the denominator."
        }
        let original = Transcript(engine: "elevenlabs", model: "scribe_v2", created_at: createdAt, segments: merged,
            schema_version: 3, speaker_detection: statuses, participant_roster: roster,
            meeting_title: meta.meetingTitle, variant: "elevenlabs_original")
        var named: Transcript?
        if report.accepted {
            var updated = original
            updated.variant = "elevenlabs_named"
            let names = Dictionary(uniqueKeysWithValues: reports.compactMap { evidence in
                evidence.candidate_name.map { (evidence.speaker, $0) }
            })
            for index in updated.segments.indices {
                let segment = updated.segments[index]
                if let name = names[segment.speaker] {
                    updated.segments[index].speaker_name = name
                    updated.segments[index].attribution = "meeting_timeline"
                } else if segment.source == "mic", !meta.sharedMicrophone, let name = meta.localSpeakerName {
                    updated.segments[index].speaker_name = name
                    updated.segments[index].attribution = "local_microphone"
                }
            }
            named = updated
        }
        return Output(original: original, named: named, report: report, analysis: analysis)
    }
}

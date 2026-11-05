import Foundation

/// Maps provider diarization to recorded active-speaker evidence. No local
/// speaker model, voice memory or text cleanup is used. On the combined meeting
/// recording two labelled inferences can complete the names: the one voice heard
/// mostly in microphone-only windows is the local user, and the last unnamed
/// voice gets the last unused roster name when voices and names number the same.
enum ElevenLabsTranscripts {
    static let threshold = 0.95
    /// Observed evidence must cover this share of a speaker's speech. A remote
    /// border lit by line noise can leak into a pause in another voice; a few
    /// milliseconds of it must not name that whole voice at 100% agreement.
    static let minimumObservedFraction = 0.25
    /// The local voice: at least this share of its single-source audio is
    /// microphone-only, covering a quarter of its speech and a few seconds.
    static let localMajorityShare = 0.9
    static let localMinimumSeconds = 5.0
    /// No other voice may be mostly microphone-only (a second person in the room).
    static let otherLocalShareLimit = 0.5

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
        /// Passed the evidence gate (95% agreement over 25% of the speech).
        let accepted: Bool
        /// Seconds of this voice in microphone-only and remote-only windows of
        /// the combined recording; nil without a combined recording.
        var local_seconds: Double? = nil
        var remote_seconds: Double? = nil
        /// The name this voice gets in the named copy, and how: meeting_timeline
        /// (evidence), local_microphone_majority or roster_elimination.
        var name: String? = nil
        var attribution: String? = nil
    }

    struct MappingReport: Codable {
        var threshold = ElevenLabsTranscripts.threshold
        var minimum_observed_fraction = ElevenLabsTranscripts.minimumObservedFraction
        var rule = "Every remote speaker needs >=95% agreement by observed speech duration, observed over >=25% of their speech. Missing evidence fails; unobserved speech is excluded from the agreement denominator."
        var inference: String? = nil
        /// Every speaker has a name, by evidence or inference: a named copy exists.
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

    /// Seconds of `turns` (sorted, disjoint) inside the manifest's local and remote windows.
    static func sourceSeconds(_ turns: [SpeakerTurn], _ manifest: MeetingAudio.Manifest) -> (local: Double, remote: Double) {
        let intervals = union(turns.map { Interval(start: $0.start, end: $0.end) })
        return (overlap(intervals, manifest.local_windows), overlap(intervals, manifest.remote_windows))
    }

    private static func overlap(_ intervals: [Interval], _ windows: [MeetingAudio.Span]) -> Double {
        // Both lists are sorted and disjoint.
        var i = 0, j = 0, total = 0.0
        while i < intervals.count, j < windows.count {
            total += max(0, min(intervals[i].end, windows[j].end) - max(intervals[i].start, windows[j].start))
            if intervals[i].end < windows[j].end { i += 1 } else { j += 1 }
        }
        return total
    }

    /// Names the combined recording's unnamed voices by microphone majority, then
    /// by elimination against the roster. Evidence-backed names are never changed,
    /// and a voice whose evidence names someone else blocks the inference.
    static func infer(_ reports: inout [SpeakerEvidenceReport], roster: ParticipantRoster,
                              localName: String?, sharedMicrophone: Bool) {
        func same(_ lhs: String?, _ rhs: String?) -> Bool {
            guard let lhs, let rhs else { return false }
            return lhs.caseInsensitiveCompare(rhs) == .orderedSame
        }
        // Substantial evidence for someone else: a majority over the coverage
        // floor, short only of 95%. A stray lit border in a pause does not count.
        func contradicts(_ report: SpeakerEvidenceReport, _ name: String) -> Bool {
            guard let candidate = report.candidate_name, !same(candidate, name) else { return false }
            return report.agreement >= 0.5 && report.observed_fraction + 1e-10 >= minimumObservedFraction
        }
        if let localName, !sharedMicrophone,
           !reports.contains(where: { $0.name != nil && same($0.name, localName) }) {
            func share(_ report: SpeakerEvidenceReport) -> Double {
                let local = report.local_seconds ?? 0, total = local + (report.remote_seconds ?? 0)
                return total > 0 ? local / total : 0
            }
            let candidates = reports.indices.filter { index in
                let report = reports[index], local = report.local_seconds ?? 0
                return report.provider_speaker_id != nil && share(report) >= localMajorityShare
                    && local >= localMinimumSeconds && local >= minimumObservedFraction * report.speech_seconds
            }
            if candidates.count == 1, let index = candidates.first, reports[index].name == nil,
               !contradicts(reports[index], localName),
               !reports.indices.contains(where: { $0 != index && share(reports[$0]) >= otherLocalShareLimit }) {
                reports[index].name = localName
                reports[index].attribution = "local_microphone_majority"
            }
        }
        var names: [String] = []
        for participant in roster.participants {
            if let name = SpeakerAttribution.cleanName(participant.name), !names.contains(where: { same($0, name) }) { names.append(name) }
        }
        let voices = reports.indices.filter { reports[$0].provider_speaker_id != nil }
        let named = voices.compactMap { reports[$0].name }
        let unnamed = voices.filter { reports[$0].name == nil }
        let unused = names.filter { name in !named.contains(where: { same($0, name) }) }
        // Every assigned name is a distinct roster member, so the counts mean something.
        guard voices.count == reports.count, names.count == voices.count, unnamed.count == 1, unused.count == 1,
              Set(named.map { $0.lowercased() }).count == named.count,
              named.allSatisfy({ name in names.contains(where: { same($0, name) }) }),
              let index = unnamed.first, let name = unused.first, !contradicts(reports[index], name) else { return }
        reports[index].name = name
        reports[index].attribution = "roster_elimination"
    }

    static func build(meta: SessionMeta, tracks: [TrackResult], roster: ParticipantRoster,
                      observations: [SpeakerObservation], inferNames: Bool = true,
                      createdAt: String = ISO8601DateFormatter().string(from: Date())) -> Output {
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
            var trackReports: [SpeakerEvidenceReport] = []
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
                    && observed / duration + 1e-10 >= minimumObservedFraction
                var report = SpeakerEvidenceReport(speaker: id, provider_speaker_id: providerIDs[id], candidate_name: name,
                    agreement: agreement, observed_seconds: observed, speech_seconds: duration,
                    observed_fraction: duration > 0 ? observed / duration : 0, ambiguous_seconds: ambiguous, accepted: accepted)
                if accepted { report.name = name; report.attribution = "meeting_timeline" }
                if source == "meeting", let windows = result.meetingAudio {
                    report.local_seconds = overlap(own, windows.local_windows)
                    report.remote_seconds = overlap(own, windows.remote_windows)
                }
                trackReports.append(report)
            }
            if inferNames, source == "meeting", result.meetingAudio != nil {
                infer(&trackReports, roster: roster, localName: meta.localSpeakerName, sharedMicrophone: meta.sharedMicrophone)
            }
            reports += trackReports
        }
        merged.sort { $0.start_ms < $1.start_ms }
        analysis.turns.sort { $0.start < $1.start }
        var report = MappingReport(accepted: !reports.isEmpty && reports.allSatisfy { $0.name != nil }, speakers: reports)
        if tracks.contains(where: { $0.track.source == "meeting" }) {
            report.rule = "Every speaker in the combined meeting recording needs >=95% agreement by observed speech duration, observed over >=25% of their speech. Only clear matching-source audio windows may vote. Missing evidence fails; unobserved speech is excluded from the agreement denominator."
            if inferNames {
                report.inference = "Unnamed voices may be inferred and are labelled so: local_microphone_majority when exactly one voice is >=90% microphone-only (>=5 s, >=25% of its speech) and no other voice is >=50%; then roster_elimination when voices and distinct roster names are equal in number and exactly one voice and one name remain. Evidence naming someone else blocks either inference."
            }
        }
        let original = Transcript(engine: "elevenlabs", model: "scribe_v2", created_at: createdAt, segments: merged,
            schema_version: 3, speaker_detection: statuses, participant_roster: roster,
            meeting_title: meta.meetingTitle, variant: "elevenlabs_original")
        var named: Transcript?
        if report.accepted {
            var updated = original
            updated.variant = "elevenlabs_named"
            let names = Dictionary(uniqueKeysWithValues: reports.compactMap { evidence in
                evidence.name.map { (evidence.speaker, (name: $0, attribution: evidence.attribution ?? "meeting_timeline")) }
            })
            for index in updated.segments.indices {
                let segment = updated.segments[index]
                if let assigned = names[segment.speaker] {
                    updated.segments[index].speaker_name = assigned.name
                    updated.segments[index].attribution = assigned.attribution
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

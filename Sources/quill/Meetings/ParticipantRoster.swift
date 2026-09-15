import Foundation

struct RosterMember: Codable, Equatable, Sendable {
    let name: String
    let is_local: Bool
}

struct MeetingParticipant: Codable, Sendable {
    let name: String
    let is_local: Bool
    var first_seen: Double
    var last_seen: Double
    var sources: [String]
}

/// Membership observations are separate from speaking indicators. A complete
/// observation must reconcile named people with the meeting's participant count.
struct ParticipantRoster: Codable, Sendable {
    struct Interval: Codable, Sendable {
        let meeting_id: String
        let start: Double
        var end: Double
        let remote_names: [String]
        let complete: Bool
    }

    var audio_started_at: Double
    var participants: [MeetingParticipant] = []
    var intervals: [Interval] = []
    var confirmed_sole_remote_speaker: String? = nil

    mutating func observe(_ observation: SpeakerObservation, localName: String?) {
        guard observation.observed_at.isFinite, observation.observed_at >= audio_started_at - 10 else { return }
        let members = observation.participants ?? observation.names.compactMap { name in
            SpeakerAttribution.cleanName(name).map { RosterMember(name: $0, is_local: observation.is_local == true) }
        }
        for member in members {
            guard let name = SpeakerAttribution.cleanName(member.name) else { continue }
            let local = member.is_local || SpeakerAttribution.isLocalName(name, localName: localName)
            if let index = participants.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame && $0.is_local == local }) {
                participants[index].first_seen = min(participants[index].first_seen, observation.observed_at)
                participants[index].last_seen = max(participants[index].last_seen, observation.observed_at)
                if !participants[index].sources.contains(observation.source) { participants[index].sources.append(observation.source) }
            } else {
                participants.append(.init(name: name, is_local: local, first_seen: observation.observed_at,
                                          last_seen: observation.observed_at, sources: [observation.source]))
            }
        }
        guard observation.source == "meeting_roster" else { return }
        let remote = members.filter { !$0.is_local && !SpeakerAttribution.isLocalName($0.name, localName: localName) }
            .compactMap { SpeakerAttribution.cleanName($0.name) }.sorted()
        let unique = Set(remote.map { $0.lowercased() })
        let complete = observation.roster_complete == true && observation.participant_count == remote.count + 1
            && unique.count == remote.count && SpeakerAttribution.cleanName(localName) != nil
        let time = observation.observed_at
        if let last = intervals.last, time < last.end { return }
        if let last = intervals.last, last.meeting_id == observation.meeting_id,
           last.remote_names == remote, last.complete == complete, time - last.end <= 15 {
            intervals[intervals.count - 1].end = time
        } else {
            intervals.append(.init(meeting_id: observation.meeting_id, start: time, end: time, remote_names: remote, complete: complete))
        }
    }

    func soleRemoteIdentity(startMS: Int, endMS: Int) -> SpeakerIdentity? {
        guard startMS >= 0, endMS >= startMS else { return nil }
        if let name = confirmed_sole_remote_speaker, SpeakerAttribution.cleanName(name) == name {
            return .init(name: name, source: "confirmed_participant", evidence_count: 1)
        }
        let start = audio_started_at + Double(startMS) / 1000
        let end = audio_started_at + Double(endMS) / 1000
        // No inference across blind periods or a change in membership. A short
        // grace period covers the normal two-second polling cadence only.
        let observedIndex = intervals.lastIndex(where: { $0.start <= start })
        let initialIndex = intervals.first.map { $0.start - audio_started_at <= 5 ? 0 : nil } ?? nil
        guard let index = observedIndex ?? initialIndex else { return nil }
        let interval = intervals[index]
        guard interval.complete, interval.remote_names.count == 1, interval.end - interval.start >= 2,
              end <= interval.end + 5,
              index + 1 == intervals.count || end < intervals[index + 1].start else { return nil }
        return .init(name: interval.remote_names[0], source: "participant_roster", evidence_count: 2)
    }

    func permits(_ name: String, for segment: Transcript.Segment) -> Bool {
        guard segment.source == "system", segment.attribution != "manual",
              let identity = soleRemoteIdentity(startMS: segment.start_ms, endMS: segment.end_ms) else { return false }
        if confirmed_sole_remote_speaker == nil, let existing = segment.speaker_name,
           existing.caseInsensitiveCompare(identity.name) != .orderedSame { return false }
        return identity.name.caseInsensitiveCompare(name) == .orderedSame
    }

    func relabel(_ segments: [Transcript.Segment]) -> [Transcript.Segment] {
        segments.map { segment in
            guard segment.source == "system", segment.attribution != "manual",
                  let identity = soleRemoteIdentity(startMS: segment.start_ms, endMS: segment.end_ms) else { return segment }
            // A contradictory contemporaneous name defeats roster inference.
            if let name = segment.speaker_name {
                if name.caseInsensitiveCompare(identity.name) == .orderedSame { return segment }
                if confirmed_sole_remote_speaker == nil { return segment }
            }
            var updated = segment
            updated.speaker = SpeakerAttribution.namedSpeakerID(identity, source: "system")
            updated.speaker_name = identity.name
            updated.attribution = identity.source
            return updated
        }
    }
}

enum ParticipantEvidence {
    static func members(_ nodes: [SpeakerUINode], service: String, localName: String?) -> [RosterMember] {
        var result: [RosterMember] = []
        func add(_ raw: String, local: Bool = false) {
            let name = local && ["You", "Tu"].contains(raw) ? localName : raw
            guard let name = SpeakerAttribution.cleanName(name) else { return }
            let member = RosterMember(name: name, is_local: local || SpeakerAttribution.isLocalName(name, localName: localName))
            if !result.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame && $0.is_local == member.is_local }) { result.append(member) }
        }
        func descendant(_ index: Int, of ancestor: Int) -> Bool {
            var parent = nodes[index].parent
            var seen: Set<Int> = []
            while let next = parent, nodes.indices.contains(next), seen.insert(next).inserted {
                if next == ancestor { return true }
                parent = nodes[next].parent
            }
            return false
        }
        if service == "Google Meet" {
            // Names remain available on silent/camera-off tiles, even when a
            // speaking indicator is absent or its DOM structure changes.
            for index in nodes.indices where nodes[index].classes.contains("OFfHfd") {
                let names = nodes.indices.filter { nodes[$0].role == "AXStaticText" && descendant($0, of: index) && !nodes[$0].text.isEmpty }
                if names.count == 1, let name = names.first { add(nodes[name].text, local: nodes[index].classes.contains("eQJ1qd")) }
            }
        } else if service == "Microsoft Teams" {
            for index in nodes.indices where nodes[index].classes.contains("vdi-occlusion") {
                let names = nodes.indices.filter { nodes[$0].role == "AXStaticText" && descendant($0, of: index) && !nodes[$0].text.isEmpty }
                if names.count == 1, let name = names.first { add(nodes[name].text) }
            }
        } else if service == "Slack" {
            for tile in SlackTileEvidence.tiles(nodes) { add(tile.name) }
        } else if service == "Zoom" {
            for node in nodes where node.roleDescription == "video render" {
                if let video = ZoomSpeakerEvidence.participant(description: node.text, frame: .zero, localName: localName) { add(video.name, local: video.isLocal) }
            }
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func participantCount(_ nodes: [SpeakerUINode]) -> Int? {
        let labels = ["participants", "people", "show everyone", "everyone", "in this call", "participanți", "persoane"]
        var counts: Set<Int> = []
        for (index, node) in nodes.enumerated() where ["AXButton", "AXTab", "AXHeading"].contains(node.role) {
            let texts = node.text.lowercased().split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            for text in texts {
                for label in labels {
                    let pattern = "^(?:" + NSRegularExpression.escapedPattern(for: label) + #"\s*[:(,]?\s*(\d+)\)?|(\d+)\s*"# + NSRegularExpression.escapedPattern(for: label) + ")$"
                    if let regex = try? NSRegularExpression(pattern: pattern),
                       let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) {
                        for group in 1...2 where match.range(at: group).location != NSNotFound {
                            if let range = Range(match.range(at: group), in: text), let count = Int(text[range]), (1...1000).contains(count) { counts.insert(count) }
                        }
                    }
                }
                if labels.contains(text) {
                    for child in nodes where child.role == "AXStaticText" {
                        var parent = child.parent
                        var seen: Set<Int> = []
                        while let current = parent, current != index, nodes.indices.contains(current), seen.insert(current).inserted { parent = nodes[current].parent }
                        guard parent == index else { continue }
                        if let count = Int(child.text), (1...1000).contains(count) { counts.insert(count) }
                    }
                }
            }
        }
        return counts.count == 1 ? counts.first : nil
    }
}

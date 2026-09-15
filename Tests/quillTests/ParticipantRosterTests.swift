import XCTest
@testable import quill

final class ParticipantRosterTests: XCTestCase {
    private func observation(_ time: Double, names: [String] = ["Mihai"], count: Int? = 2, complete: Bool = true) -> SpeakerObservation {
        SpeakerObservation(observed_at: 1000 + time, meeting_id: "meet", names: [], source: "meeting_roster",
                           participants: names.map { RosterMember(name: $0, is_local: false) }, participant_count: count, roster_complete: complete)
    }

    private func roster() -> ParticipantRoster {
        var result = ParticipantRoster(audio_started_at: 1000)
        for time in stride(from: 0.0, through: 20.0, by: 2) { result.observe(observation(time), localName: "Dragos") }
        return result
    }

    func testTwoPersonRosterResolvesAllAcousticIDsAndVADGaps() {
        let segments = ["system_1", "system_2", "system_unknown"].enumerated().map { index, id in
            Transcript.Segment(speaker: id, start_ms: index * 4000, end_ms: index * 4000 + 1000,
                               text: "Exact wording \(index).", source: "system", attribution: "diarization")
        }
        let result = roster().relabel(segments)
        XCTAssertEqual(result.map(\.speaker_name), ["Mihai", "Mihai", "Mihai"])
        XCTAssertEqual(Set(result.map(\.speaker)).count, 1)
        XCTAssertEqual(result.map(\.text), segments.map(\.text))
        XCTAssertEqual(result.map(\.start_ms), segments.map(\.start_ms))
        XCTAssertEqual(result.map(\.end_ms), segments.map(\.end_ms))
    }

    func testSilentParticipantsJoinLeaveAndPersistInRoster() {
        var result = roster()
        result.observe(observation(22, names: ["Mihai", "Alice"], count: 3), localName: "Dragos")
        result.observe(observation(24, names: ["Alice"], count: 2), localName: "Dragos")
        result.observe(observation(26, names: ["Alice"], count: 2), localName: "Dragos")
        XCTAssertEqual(result.participants.map(\.name), ["Mihai", "Alice"])
        XCTAssertEqual(result.participants[0].last_seen, 1022)
        XCTAssertEqual(result.participants[1].first_seen, 1022)
        XCTAssertEqual(result.soleRemoteIdentity(startMS: 5000, endMS: 6000)?.name, "Mihai")
        XCTAssertNil(result.soleRemoteIdentity(startMS: 22000, endMS: 23000))
        XCTAssertEqual(result.soleRemoteIdentity(startMS: 25000, endMS: 26000)?.name, "Alice")
        XCTAssertNil(result.soleRemoteIdentity(startMS: 21000, endMS: 23000), "A turn spanning a new arrival must not inherit the earlier sole speaker")
    }

    func testPartialRosterAndBlindPeriodsCannotInventSoleSpeaker() {
        for count in [nil, 3] as [Int?] {
            var result = ParticipantRoster(audio_started_at: 1000)
            result.observe(observation(0, count: count), localName: "Dragos")
            result.observe(observation(2, count: count), localName: "Dragos")
            XCTAssertNil(result.soleRemoteIdentity(startMS: 1000, endMS: 2000))
        }
        var result = roster()
        result.observe(observation(60), localName: "Dragos")
        result.observe(observation(62), localName: "Dragos")
        XCTAssertNil(result.soleRemoteIdentity(startMS: 40000, endMS: 41000))
        XCTAssertEqual(result.soleRemoteIdentity(startMS: 61000, endMS: 62000)?.name, "Mihai")
        XCTAssertEqual(result.participants.count, 1, "A UI gap must not delete the known participant")
    }

    func testInitialRosterCoversOpeningWordsButLateArrivalDoesNotRewriteThePast() {
        var initial = ParticipantRoster(audio_started_at: 1000)
        initial.observe(observation(2), localName: "Dragos")
        initial.observe(observation(4), localName: "Dragos")
        XCTAssertEqual(initial.soleRemoteIdentity(startMS: 150, endMS: 1000)?.name, "Mihai")
        var late = ParticipantRoster(audio_started_at: 1000)
        late.observe(observation(20), localName: "Dragos")
        late.observe(observation(22), localName: "Dragos")
        XCTAssertNil(late.soleRemoteIdentity(startMS: 150, endMS: 1000))
    }

    func testConfirmedSoleParticipantCoversMissingUIWithoutTouchingMicrophoneOrManualLabels() {
        var result = ParticipantRoster(audio_started_at: 1000)
        result.confirmed_sole_remote_speaker = "Mihai"
        let segments = [Transcript.Segment(speaker: "system_unknown", start_ms: 2000000, end_ms: 2001000, text: "Hello", source: "system"),
                        .init(speaker: "me", start_ms: 0, end_ms: 1000, text: "Hi", source: "mic", speaker_name: "Dragos", attribution: "local_microphone"),
                        .init(speaker: "system_1", start_ms: 0, end_ms: 1000, text: "Manual", source: "system", speaker_name: "Reviewed", attribution: "manual")]
        let updated = result.relabel(segments)
        XCTAssertEqual(updated.map(\.speaker_name), ["Mihai", "Dragos", "Reviewed"])
        XCTAssertEqual(updated[1].speaker, "me")
        XCTAssertEqual(updated[2].attribution, "manual")
    }

    func testMeetMembershipDoesNotRequireSpeakingIndicator() {
        let nodes = [SpeakerUINode(parent: nil, role: "AXGroup", text: "", classes: []),
                     .init(parent: 0, role: "AXGroup", text: "", classes: ["OFfHfd"]),
                     .init(parent: 1, role: "AXStaticText", text: "Mihai", classes: []),
                     .init(parent: 0, role: "AXGroup", text: "", classes: ["OFfHfd", "eQJ1qd"]),
                     .init(parent: 3, role: "AXStaticText", text: "You", classes: []),
                     .init(parent: 0, role: "AXButton", text: "Show everyone", classes: []),
                     .init(parent: 5, role: "AXStaticText", text: "2", classes: [])]
        XCTAssertTrue(MeetTileEvidence.tiles(nodes).isEmpty)
        XCTAssertEqual(ParticipantEvidence.members(nodes, service: "Google Meet", localName: "Dragos"),
                       [.init(name: "Dragos", is_local: true), .init(name: "Mihai", is_local: false)])
        XCTAssertEqual(ParticipantEvidence.participantCount(nodes), 2)
    }

    func testCountsMustBeExplicitAndUnambiguous() {
        func node(_ text: String, role: String = "AXButton") -> SpeakerUINode {
            .init(parent: nil, role: role, text: text, classes: [])
        }
        XCTAssertEqual(ParticipantEvidence.participantCount([node("Participants (3)")]), 3)
        XCTAssertNil(ParticipantEvidence.participantCount([node("Participants (3)"), node("2 people")]))
        XCTAssertNil(ParticipantEvidence.participantCount([node("There are 2 people in my team", role: "AXStaticText")]))
        XCTAssertEqual(ParticipantEvidence.participantCount([node("Participants\nParticipants (3)")]), 3)
    }

    func testTeamsRosterSurvivesMissingSpeakingBorderAndZoomUsesParticipantAudioLabels() {
        let teams = [SpeakerUINode(parent: nil, role: "AXGroup", text: "", classes: ["vdi-occlusion"]),
                     .init(parent: 0, role: "AXStaticText", text: "Mihai", classes: [])]
        XCTAssertTrue(TeamsTileEvidence.tiles(teams).isEmpty)
        XCTAssertEqual(ParticipantEvidence.members(teams, service: "Microsoft Teams", localName: "Dragos").map(\.name), ["Mihai"])
        let zoom = [SpeakerUINode(parent: nil, role: "AXTabGroup", text: "Mihai, Computer audio muted, Video off", classes: [], roleDescription: "video render")]
        XCTAssertEqual(ParticipantEvidence.members(zoom, service: "Zoom", localName: "Dragos").map(\.name), ["Mihai"])
    }

    func testRecordingPersistsMembershipBeforeTranscription() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("quill-roster-recording-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try RecordingSession(root: root)
        let time = session.startedAt.timeIntervalSince1970 + 1
        let sample = SpeakerObservation(observed_at: time, meeting_id: "meet", names: [], source: "meeting_roster",
            participants: [.init(name: "Mihai", is_local: false)], participant_count: 2, roster_complete: true)
        session.recordSpeakers(sample)
        session.recordSpeakers(sample)
        let saved = try JSONDecoder().decode(ParticipantRoster.self, from: Data(contentsOf: session.dir.appendingPathComponent("participants.json")))
        XCTAssertTrue(saved.participants.contains { $0.name == "Mihai" })
        let observations = try String(contentsOf: session.dir.appendingPathComponent("speaker-observations.jsonl"), encoding: .utf8)
        XCTAssertEqual(observations.split(separator: "\n").count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.dir.appendingPathComponent("transcript.json").path))
    }

    func testDuplicateNamesCannotSatisfyParticipantCount() {
        var result = ParticipantRoster(audio_started_at: 1000)
        result.observe(observation(0, names: ["Mihai", "MIHAI"], count: 3), localName: "Dragos")
        result.observe(observation(2, names: ["Mihai", "MIHAI"], count: 3), localName: "Dragos")
        XCTAssertNil(result.soleRemoteIdentity(startMS: 1000, endMS: 2000))
    }

    func testConfirmedLabelPreservesCleanupAndPersistsRoster() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("quill-roster-label-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(#"{"files":{"system":"system.caf","mic":"mic.caf"},"audio_started_at":1000,"local_speaker_name":"Dragos"}"#.utf8)
            .write(to: directory.appendingPathComponent("meta.json"))
        let original = Transcript(engine: "fixture", model: "fixture", created_at: "now", segments: [
            .init(speaker: "system_unknown", start_ms: 0, end_ms: 1000, text: "Previously cleaned text.", source: "system"),
            .init(speaker: "system_2", start_ms: 2000, end_ms: 3000, text: "Exact second turn.", source: "system"),
            .init(speaker: "me", start_ms: 3000, end_ms: 4000, text: "My turn.", source: "mic", speaker_name: "Dragos")
        ], schema_version: 2)
        try original.write(to: directory)
        let bytes = try Data(contentsOf: directory.appendingPathComponent("transcript.json"))
        let command = try LabelSpeaker.parse([directory.path, "--sole-remote-speaker", "--name", "Mihai"])
        try command.run()
        let updated = try JSONDecoder().decode(Transcript.self, from: Data(contentsOf: directory.appendingPathComponent("transcript.json")))
        XCTAssertEqual(updated.segments.map(\.speaker_name), ["Mihai", "Mihai", "Dragos"])
        XCTAssertEqual(updated.segments.map(\.text), original.segments.map(\.text))
        XCTAssertEqual(updated.segments.map(\.start_ms), original.segments.map(\.start_ms))
        XCTAssertEqual(updated.participant_roster?.participants.map(\.name), ["Dragos", "Mihai"])
        XCTAssertEqual(try SessionMeta.read(from: directory).participantRoster?.confirmed_sole_remote_speaker, "Mihai")
        let backups = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("speaker-label-backup-") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: backups[0].appendingPathComponent("transcript.json")), bytes)
        let markdown = try String(contentsOf: directory.appendingPathComponent("transcript.md"), encoding: .utf8)
        XCTAssertTrue(markdown.contains("## Participants\n\n- Dragos (you)\n- Mihai"))
    }
}

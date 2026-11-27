import XCTest
@testable import quill

final class SpeakerIdentitiesTests: XCTestCase {
    private func fixture() throws -> URL {
        let directory = RecordingsLibrary.canonicalDirectory(FileManager.default.temporaryDirectory.appendingPathComponent("quill-people-" + UUID().uuidString))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        try Data(#"{"started":"2026-11-17T13:26:13Z","files":{},"meeting_title":"Identity fixture"}"#.utf8)
            .write(to: directory.appendingPathComponent("meta.json"))
        var roster = ParticipantRoster(audio_started_at: 1000)
        for (name, local) in [("Jamie Morgan", false), ("Jamie Morgan", true), ("Morgan Jamie", true), ("Alex Taylor", false), ("Alexandra Taylor", false)] {
            roster.observe(.init(observed_at: 1000, meeting_id: "test", names: [name], source: "meeting_tile", is_local: local), localName: nil)
        }
        try JSONEncoder().encode(roster).write(to: directory.appendingPathComponent("participants.json"))
        try Transcript(engine: "elevenlabs", model: "scribe_v2", created_at: "fixture", segments: [
            .init(speaker: "meeting_1", start_ms: 0, end_ms: 1000, text: "First", source: "meeting", provider_speaker_id: "p0"),
            .init(speaker: "meeting_2", start_ms: 1000, end_ms: 2000, text: "Second", source: "meeting", provider_speaker_id: "p1"),
            .init(speaker: "meeting_1", start_ms: 2000, end_ms: 3000, text: "Third", source: "meeting", provider_speaker_id: "p0"),
        ], participant_roster: roster, variant: "elevenlabs_original").write(to: directory)
        let reports = ["meeting_1", "meeting_2"].map {
            ElevenLabsTranscripts.SpeakerEvidenceReport(speaker: $0, provider_speaker_id: $0, candidate_name: nil,
                agreement: 0, observed_seconds: 0, speech_seconds: 2, observed_fraction: 0, ambiguous_seconds: 0, accepted: false)
        }
        try JSONEncoder().encode(ElevenLabsTranscripts.MappingReport(accepted: false, speakers: reports))
            .write(to: directory.appendingPathComponent("speaker-mapping.json"))
        return directory
    }

    func testExplicitVoiceLinkUnlinkAndAliasesPreserveOriginalAndExports() throws {
        let directory = try fixture()
        let original = try Data(contentsOf: directory.appendingPathComponent("transcript.json"))
        let observations = try Data(contentsOf: directory.appendingPathComponent("participants.json"))
        let before = S3Markdown.signature(in: directory)
        try SpeakerNames.apply(["meeting_1": "Alex Taylor", "meeting_2": "Alexandra Taylor"], in: directory,
            groups: ["meeting_1": "alex", "meeting_2": "alex"],
            aliases: ["alexandra taylor": "Alex Taylor", "morgan jamie": "Jamie Morgan"])
        let identities = SpeakerIdentities.read(in: directory)
        XCTAssertEqual(identities.people.count, 1)
        XCTAssertEqual(identities.people[0].voices, ["meeting_1", "meeting_2"])
        let entries = try RecordingsLibrary.entries(in: directory.deletingLastPathComponent())
        let entry = try XCTUnwrap(entries.first { $0.directory == directory })
        XCTAssertEqual(entry.participants, ["Alex Taylor", "Jamie Morgan"])
        guard case .turns(let turns) = try RecordingsLibrary.transcript(in: directory, named: true) else { return XCTFail() }
        XCTAssertEqual(turns.map(\.speaker), ["Alex Taylor", "Alex Taylor", "Alex Taylor"])
        XCTAssertEqual(Set(turns.map(\.navigationID)).count, 1)
        XCTAssertEqual(Set(turns.compactMap(\.speakerID)).count, 2, "Raw voice IDs are retained")
        var navigation = SpeakerTurnNavigation()
        let person = identities.people[0].id
        XCTAssertEqual(navigation.next(person, in: turns)?.id, 0)
        XCTAssertEqual(navigation.next(person, in: turns)?.id, 1)
        XCTAssertEqual(navigation.next(person, in: turns)?.id, 2)
        XCTAssertEqual(navigation.next(person, in: turns)?.id, 0)
        XCTAssertEqual(RecordingFormat.colors(turns).count, 1)
        let exported = String(decoding: try S3Markdown.make(in: directory).data, as: UTF8.self)
        XCTAssertTrue(exported.contains("participant_names: [\"Alex Taylor\",\"Jamie Morgan\"]"))
        XCTAssertTrue(exported.contains("person_id"))
        XCTAssertTrue(exported.contains("confirmed_identities:"))
        XCTAssertTrue(exported.contains("Alex Taylor:**"))
        XCTAssertNotEqual(before, S3Markdown.signature(in: directory))
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("transcript.json")), original)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("participants.json")), observations)

        // Equal display names do not link distinct people, even after a prior link.
        try SpeakerNames.apply(["meeting_1": "Alex Taylor", "meeting_2": "Alex Taylor"], in: directory,
                               groups: ["meeting_1": person, "meeting_2": "separate"])
        guard case .turns(let separate) = try RecordingsLibrary.transcript(in: directory, named: true) else { return XCTFail() }
        XCTAssertEqual(Set(separate.map(\.navigationID)).count, 2)
        XCTAssertEqual(SpeakerIdentities.read(in: directory).aliases.count, 2)
    }

    func testAliasesDoNotImplicitlyLinkVoicesOrGuessNicknames() throws {
        let directory = try fixture()
        let original = SpeakerIdentities.read(in: directory)
        XCTAssertEqual(original.participantNames(["Jamie Morgan", "jamie  morgan", "Morgan Jamie", "Alex Taylor", "Alexandra Taylor"]),
                       ["Alex Taylor", "Alexandra Taylor", "Jamie Morgan", "Morgan Jamie"])
        try SpeakerNames.apply(["meeting_1": "Alex Taylor", "meeting_2": "Alexandra Taylor"], in: directory,
                               aliases: ["alexandra taylor": "Alex Taylor"])
        let identities = SpeakerIdentities.read(in: directory)
        XCTAssertEqual(identities.people.count, 2)
        XCTAssertEqual(Set(identities.people.compactMap(\.name)), ["Alex Taylor"])
        XCTAssertNotEqual(identities.people[0].id, identities.people[1].id)
    }

    func testRegenerationInvalidatesVoiceLinksAndRejectsStaleEdits() throws {
        let directory = try fixture()
        let url = directory.appendingPathComponent("transcript.json")
        let before = try Data(contentsOf: url)
        try SpeakerNames.apply(["meeting_1": "Alex", "meeting_2": "Alex"], in: directory,
                               groups: ["meeting_1": "alex", "meeting_2": "alex"], aliases: ["alexandra": "Alex"])
        var regenerated = try JSONDecoder().decode(Transcript.self, from: before)
        regenerated.segments[0].text = "Different transcription"
        try regenerated.write(to: directory)
        let stale = SpeakerIdentities.read(in: directory)
        XCTAssertTrue(stale.people.isEmpty)
        XCTAssertEqual(stale.canonicalName("Alexandra"), "Alex")
        XCTAssertThrowsError(try SpeakerNames.apply(["meeting_1": "Alex"], in: directory,
            expectedFingerprint: SpeakerIdentities.fingerprint(before)))
        let named = try JSONDecoder().decode(Transcript.self, from: Data(contentsOf: directory.appendingPathComponent("transcript-named.json")))
        XCTAssertTrue(stale.resolved(named).segments.allSatisfy { $0.person_id == nil })
    }

    func testInvalidLinksAndAliasCyclesDoNotReplaceSavedData() throws {
        let directory = try fixture()
        try SpeakerNames.apply(["meeting_1": "Alex"], in: directory)
        let url = directory.appendingPathComponent(SpeakerIdentities.filename), before = try Data(contentsOf: url)
        XCTAssertThrowsError(try SpeakerNames.apply(["meeting_1": "Alex", "meeting_2": "Jamie"], in: directory,
            groups: ["meeting_1": "same", "meeting_2": "same"]))
        XCTAssertThrowsError(try SpeakerNames.apply(["meeting_1": "Alex"], in: directory,
            aliases: ["Alex": "Alexandra", "Alexandra": "Alex"]))
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func testExistingMicrophoneInferenceAndManualNameRemainAvailable() throws {
        let directory = try fixture()
        var named = try JSONDecoder().decode(Transcript.self, from: Data(contentsOf: directory.appendingPathComponent("transcript.json")))
        named.segments[0].speaker_name = "Jamie"
        named.segments[0].attribution = "local_microphone_majority"
        named.segments[1].speaker_name = "Alex"
        named.segments[1].attribution = "manual"
        try named.write(to: directory, basename: "transcript-named")
        guard case .turns(let turns) = try RecordingsLibrary.transcript(in: directory, named: true) else { return XCTFail() }
        XCTAssertEqual(turns[0].speaker, "Jamie")
        XCTAssertEqual(turns[1].speaker, "Alex")
        XCTAssertEqual(SpeakerNames.state(in: directory)?.rows.map(\.name), ["Jamie", "Alex"])
    }

    @MainActor
    func testEditorLinksRenamesSeparatesCancelsAndSaves() async throws {
        let directory = try fixture()
        let model = RecordingsModel(root: directory.deletingLastPathComponent(), transcription: TranscriptionCoordinator(),
            titles: RecordingTitleCoordinator(mode: { .off }, generate: { _, _, _ in }), uploadCorrection: { _ in })
        model.browse(directory)
        for _ in 0..<200 {
            if model.speakerNames != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let rows = try XCTUnwrap(model.speakerNames?.rows)
        XCTAssertEqual(rows.count, 2)
        model.setSpeakerName("Alex Taylor", for: rows[0].speaker)
        model.linkSpeaker(rows[1], to: rows[0])
        XCTAssertEqual(model.speakerName(for: rows[1]), "Alex Taylor")
        model.setSpeakerName("Alex", for: rows[1].speaker)
        XCTAssertEqual(model.speakerName(for: rows[0]), "Alex")
        model.separateSpeaker(rows[1])
        model.setSpeakerName("Jamie", for: rows[1].speaker)
        XCTAssertEqual(model.speakerName(for: rows[0]), "Alex")
        model.setParticipantAlias("Alexandra Taylor", to: "Alex Taylor")
        model.discardSpeakerNameChanges()
        XCTAssertFalse(model.hasSpeakerChanges)
        XCTAssertEqual(model.participantAlias(for: "Alexandra Taylor"), "Alexandra Taylor")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(SpeakerIdentities.filename).path))
        model.setSpeakerName("Alex Taylor", for: rows[0].speaker)
        model.linkSpeaker(rows[1], to: rows[0])
        model.setParticipantAlias("Alexandra Taylor", to: "Alex Taylor")
        model.applySpeakerNameDrafts()
        for _ in 0..<200 {
            if !model.isApplyingSpeakerNames, model.speakerNames?.complete == true { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(model.speakerNamesError)
        XCTAssertFalse(model.hasSpeakerChanges)
        XCTAssertEqual(SpeakerIdentities.read(in: directory).people.count, 1)
        guard case .turns(let turns) = model.transcript else { return XCTFail() }
        XCTAssertEqual(Set(turns.map(\.navigationID)).count, 1)
    }
}

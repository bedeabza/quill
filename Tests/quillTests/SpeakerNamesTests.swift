import XCTest
@testable import quill

final class SpeakerNamesTests: XCTestCase {
    private func voice(_ speaker: String, candidate: String? = nil, agreement: Double = 0, observed: Double = 0,
                       local: Double? = nil, remote: Double? = nil, name: String? = nil, attribution: String? = nil)
        -> ElevenLabsTranscripts.SpeakerEvidenceReport {
        var report = ElevenLabsTranscripts.SpeakerEvidenceReport(speaker: speaker, provider_speaker_id: "p_" + speaker, candidate_name: candidate,
            agreement: agreement, observed_seconds: observed, speech_seconds: 100, observed_fraction: observed / 100,
            ambiguous_seconds: 0, accepted: false)
        report.local_seconds = local
        report.remote_seconds = remote
        report.name = name
        report.attribution = attribution
        return report
    }

    /// Recording 2026.11.05-1048 (Teams, three people): two voices have tile
    /// evidence for Casey below the gate, one is mostly the microphone.
    func testDefaultsNeverGuessFromSourceRosterOrWeakEvidence() {
        let rows = SpeakerNames.rows([
            voice("meeting_1", candidate: "Casey", agreement: 0.88, observed: 92, local: 6, remote: 102),
            voice("meeting_2", candidate: "Casey", agreement: 0.69, observed: 1.9, local: 257, remote: 2,
                  name: "Jordan Reed", attribution: "local_microphone_majority"),
            voice("meeting_3", candidate: "Riley", agreement: 0.24, observed: 52, local: 16, remote: 61),
        ], participants: ["Jordan Reed", "Riley", "Casey"], localName: "Jordan Reed", sharedMicrophone: true)
        XCTAssertEqual(rows.map(\.label), ["Speaker 1", "Speaker 2", "Speaker 3"])
        XCTAssertEqual(rows.map(\.name), [nil, nil, nil])
        XCTAssertNil(rows[1].reason)
        let crowded = SpeakerNames.rows([voice("meeting_1", candidate: "Casey", agreement: 0.9, observed: 50),
                                         voice("meeting_2", candidate: "Casey", agreement: 0.7, observed: 10)],
                                        participants: ["Jordan Reed", "Casey", "Riley"], localName: nil, sharedMicrophone: true)
        XCTAssertEqual(crowded.map(\.name), [nil, nil], "weak evidence must not preselect an identity")
    }

    func testPersonalMicrophoneKeepsExistingEditorSuggestions() {
        let rows = SpeakerNames.rows([
            voice("meeting_1", local: 90, remote: 0), voice("meeting_2", local: 0, remote: 90)
        ], participants: ["Jamie", "Alex"], localName: "Jamie")
        XCTAssertEqual(rows.map(\.name), ["Jamie", "Alex"])
        XCTAssertEqual(rows.map(\.reason), ["Mostly your microphone", "Only participant left"])
    }

    func testApplyWritesAManualNamedCopyAndKeepsTheOriginal() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("quill-speaker-names-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let original = Transcript(engine: "elevenlabs", model: "scribe_v2", created_at: "fixture", segments: [
            .init(speaker: "meeting_1", start_ms: 0, end_ms: 1000, text: "Hello.", source: "meeting", attribution: "elevenlabs", provider_speaker_id: "speaker_0"),
            .init(speaker: "meeting_2", start_ms: 1000, end_ms: 2000, text: "Hi.", source: "meeting", attribution: "elevenlabs", provider_speaker_id: "speaker_1"),
        ], schema_version: 3, variant: "elevenlabs_original")
        try original.write(to: directory)
        let report = ElevenLabsTranscripts.MappingReport(accepted: false, speakers: [voice("meeting_1"), voice("meeting_2")])
        try JSONEncoder().encode(report).write(to: directory.appendingPathComponent("speaker-mapping.json"))
        let url = directory.appendingPathComponent("transcript.json"), before = try Data(contentsOf: url)
        XCTAssertEqual(SpeakerNames.state(in: directory)?.complete, false)

        XCTAssertNil(try SpeakerNames.apply(["meeting_1": "Jordan Reed"], in: directory), "nothing replaced, nothing to back up")
        var named = try JSONDecoder().decode(Transcript.self, from: Data(contentsOf: directory.appendingPathComponent("transcript-named.json")))
        XCTAssertEqual(named.variant, "elevenlabs_named")
        XCTAssertEqual(named.segments.map(\.speaker_name), ["Jordan Reed", nil])
        XCTAssertEqual(named.segments.map(\.attribution), ["manual", "elevenlabs"])
        XCTAssertEqual(SpeakerNames.state(in: directory)?.complete, false, "Speaker 2 is still unnamed")

        let backup = try XCTUnwrap(SpeakerNames.apply(["meeting_1": "Jordan Reed", "meeting_2": "Casey"], in: directory))
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.appendingPathComponent("transcript-named.json").path))
        named = try JSONDecoder().decode(Transcript.self, from: Data(contentsOf: directory.appendingPathComponent("transcript-named.json")))
        XCTAssertEqual(named.segments.map(\.speaker_name), ["Jordan Reed", "Casey"])
        let state = try XCTUnwrap(SpeakerNames.state(in: directory))
        XCTAssertTrue(state.complete)
        XCTAssertEqual(state.rows.map(\.reason), ["Chosen by you", "Chosen by you"])
        XCTAssertEqual(try Data(contentsOf: url), before, "the original transcript is never edited")
        XCTAssertThrowsError(try SpeakerNames.apply(["meeting_9": "Nobody"], in: directory))
    }

    /// Found in review: after naming only Speaker 2 "Bob", Speaker 1's tile
    /// evidence for Bob pre-selected Bob a second time.
    func testNamesFromThePartialNamedCopyAreNotSuggestedAgain() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("quill-speaker-names-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        try Data(#"{"files":{},"shared_microphone":true}"#.utf8).write(to: directory.appendingPathComponent("meta.json"))
        var roster = ParticipantRoster(audio_started_at: 1000)
        roster.participants = ["Jordan Reed", "Bob"].map { .init(name: $0, is_local: $0 == "Jordan Reed", first_seen: 1000, last_seen: 1010, sources: ["meeting_roster"]) }
        try Transcript(engine: "elevenlabs", model: "scribe_v2", created_at: "fixture", segments: [
            .init(speaker: "meeting_1", start_ms: 0, end_ms: 1000, text: "Hello.", source: "meeting", attribution: "elevenlabs", provider_speaker_id: "speaker_0"),
            .init(speaker: "meeting_2", start_ms: 1000, end_ms: 2000, text: "Hi.", source: "meeting", attribution: "elevenlabs", provider_speaker_id: "speaker_1"),
        ], schema_version: 3, participant_roster: roster, variant: "elevenlabs_original").write(to: directory)
        let report = ElevenLabsTranscripts.MappingReport(accepted: false, speakers: [
            voice("meeting_1", candidate: "Bob", agreement: 0.9, observed: 50, local: 0, remote: 0), voice("meeting_2", local: 0, remote: 0)])
        try JSONEncoder().encode(report).write(to: directory.appendingPathComponent("speaker-mapping.json"))
        XCTAssertEqual(SpeakerNames.state(in: directory)?.rows.map(\.name), [nil, nil])
        try SpeakerNames.apply(["meeting_2": "Bob"], in: directory)
        XCTAssertEqual(SpeakerNames.state(in: directory)?.rows.map(\.name), [nil, "Bob"])
        // The CLI names one voice and keeps the other's name and attribution.
        try SpeakerNames.apply(["meeting_1": "Jordan Reed"], in: directory, keepingOtherNames: true)
        let named = try JSONDecoder().decode(Transcript.self, from: Data(contentsOf: directory.appendingPathComponent("transcript-named.json")))
        XCTAssertEqual(named.segments.map(\.speaker_name), ["Jordan Reed", "Bob"])
    }
}

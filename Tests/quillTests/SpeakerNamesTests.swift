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
    /// evidence for Bogdan below the gate, one is mostly the microphone.
    func testDefaultsNeverRepeatANameAndFallBackToTheLastParticipant() {
        let rows = SpeakerNames.rows([
            voice("meeting_1", candidate: "Bogdan", agreement: 0.88, observed: 92, local: 6, remote: 102),
            voice("meeting_2", candidate: "Bogdan", agreement: 0.69, observed: 1.9, local: 257, remote: 2,
                  name: "Dragos Badea", attribution: "local_microphone_majority"),
            voice("meeting_3", candidate: "Marian", agreement: 0.24, observed: 52, local: 16, remote: 61),
        ], participants: ["Dragos Badea", "Marian", "Bogdan"], localName: "Dragos Badea")
        XCTAssertEqual(rows.map(\.label), ["Speaker 1", "Speaker 2", "Speaker 3"])
        XCTAssertEqual(rows.map(\.name), ["Bogdan", "Dragos Badea", "Marian"])
        XCTAssertEqual(rows[1].reason, "Mostly your microphone")
        let crowded = SpeakerNames.rows([voice("meeting_1", candidate: "Bogdan", agreement: 0.9, observed: 50),
                                         voice("meeting_2", candidate: "Bogdan", agreement: 0.7, observed: 10)],
                                        participants: ["Dragos Badea", "Bogdan", "Marian"], localName: nil)
        XCTAssertEqual(crowded.map(\.name), ["Bogdan", nil], "two open names left: no guess")
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

        XCTAssertNil(try SpeakerNames.apply(["meeting_1": "Dragos Badea"], in: directory), "nothing replaced, nothing to back up")
        var named = try JSONDecoder().decode(Transcript.self, from: Data(contentsOf: directory.appendingPathComponent("transcript-named.json")))
        XCTAssertEqual(named.variant, "elevenlabs_named")
        XCTAssertEqual(named.segments.map(\.speaker_name), ["Dragos Badea", nil])
        XCTAssertEqual(named.segments.map(\.attribution), ["manual", "elevenlabs"])
        XCTAssertEqual(SpeakerNames.state(in: directory)?.complete, false, "Speaker 2 is still unnamed")

        let backup = try XCTUnwrap(SpeakerNames.apply(["meeting_1": "Dragos Badea", "meeting_2": "Bogdan"], in: directory))
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.appendingPathComponent("transcript-named.json").path))
        named = try JSONDecoder().decode(Transcript.self, from: Data(contentsOf: directory.appendingPathComponent("transcript-named.json")))
        XCTAssertEqual(named.segments.map(\.speaker_name), ["Dragos Badea", "Bogdan"])
        let state = try XCTUnwrap(SpeakerNames.state(in: directory))
        XCTAssertTrue(state.complete)
        XCTAssertEqual(state.rows.map(\.reason), ["Chosen by you", "Chosen by you"])
        XCTAssertEqual(try Data(contentsOf: url), before, "the original transcript is never edited")
        XCTAssertThrowsError(try SpeakerNames.apply(["meeting_9": "Nobody"], in: directory))
    }
}

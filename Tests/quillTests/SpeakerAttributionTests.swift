import XCTest
@testable import quill

final class SpeakerAttributionTests: XCTestCase {
    func testCaptionNamesCannotSpreadAcrossAMergedAcousticCluster() throws {
        let a = "the first person has eight clearly matching words today".split(separator: " ")
        let b = "another person says something completely different over here now".split(separator: " ")
        func segment(_ tokens: [Substring], at start: Double) -> TranscriptSegment {
            let words = tokens.enumerated().map { TranscriptWord(start: start + Double($0.offset), end: start + Double($0.offset + 1), text: String($0.element)) }
            return TranscriptSegment(start: start, end: start + Double(tokens.count), text: tokens.joined(separator: " "), words: words)
        }
        let segments = [segment(a, at: 0), segment(b, at: 20)]
        let turns = [SpeakerTurn(speaker_id: "system_1", start: 0, end: 30)]
        let alice = try XCTUnwrap(SpeakerEvidence.caption(texts: ["Alice", a.joined(separator: " ")], meetingID: "test", observedAt: 12))
        let spans = SpeakerAttribution.nameSpans(turns: turns, observations: [alice], audioStartedAt: 0, segments: segments)
        let result = SpeakerAttribution.align(segments, turns: turns, source: "system", offset: 0, namedSpans: spans)
        XCTAssertEqual(result[0].speaker_name, "Alice")
        XCTAssertNil(result[1].speaker_name)
        let bob = try XCTUnwrap(SpeakerEvidence.caption(texts: ["Bob", b.joined(separator: " ")], meetingID: "test", observedAt: 32))
        let both = SpeakerAttribution.nameSpans(turns: turns, observations: [alice, bob], audioStartedAt: 0, segments: segments)
        let named = SpeakerAttribution.align(segments, turns: turns, source: "system", offset: 0, namedSpans: both)
        XCTAssertEqual(named.map(\.speaker_name), ["Alice", "Bob"])
        XCTAssertNotEqual(named[0].speaker, named[1].speaker)
    }

    func testLiveMeetCaptionShapeAndDelayedTextAlignment() throws {
        let captured = try XCTUnwrap(SpeakerEvidence.caption(texts: ["Alice", "I just said two or three sentences.", "This is a test.", "Hello! Hello, hello!"],
                                                            meetingID: "meet", observedAt: 115))
        XCTAssertEqual(captured.names, ["Alice"])
        XCTAssertFalse(captured.is_local ?? true)
        let phrase = "I just said two or three sentences This is a test Hello Hello hello".split(separator: " ")
        let words = phrase.enumerated().map { TranscriptWord(start: Double($0.offset) * 0.5, end: Double($0.offset + 1) * 0.5, text: String($0.element)) }
        let segments = [TranscriptSegment(start: 0, end: 7, text: phrase.joined(separator: " "), words: words)]
        let turns = [SpeakerTurn(speaker_id: "system_1", start: 0, end: 7)]
        let named = SpeakerAttribution.nameSpans(turns: turns, observations: [captured], audioStartedAt: 100, segments: segments)
        XCTAssertEqual(named.first?.identity.name, "Alice")
        XCTAssertEqual(named.first?.identity.source, "meeting_caption")
        var local = captured
        local.is_local = true
        XCTAssertTrue(SpeakerAttribution.nameSpans(turns: turns, observations: [local], audioStartedAt: 100, segments: segments).isEmpty)
        XCTAssertTrue(SpeakerAttribution.nameSpans(turns: turns, observations: [captured], audioStartedAt: 0, segments: segments).isEmpty)
        let short = try XCTUnwrap(SpeakerEvidence.caption(texts: ["Alice", "This is a test"], meetingID: "meet", observedAt: 110))
        XCTAssertTrue(SpeakerAttribution.nameSpans(turns: turns, observations: Array(repeating: short, count: 10), audioStartedAt: 100, segments: segments).isEmpty)
        XCTAssertNil(SpeakerEvidence.caption(texts: ["Summarize captions"], meetingID: "meet", observedAt: 100))
    }

    func testNamesRequireSustainedSingleSpeakerEvidence() {
        let turns = [SpeakerTurn(speaker_id: "system_1", start: 0, end: 12)]
        let samples = [2.0, 4, 6].map { SpeakerObservation(observed_at: 100 + $0, meeting_id: "meet", names: ["Alice"]) }
        let names = SpeakerAttribution.names(turns: turns, observations: samples, audioStartedAt: 100)
        XCTAssertEqual(names["system_1"]?.name, "Alice")
        XCTAssertTrue(SpeakerAttribution.names(turns: turns, observations: Array(samples.prefix(2)), audioStartedAt: 100).isEmpty)
        XCTAssertTrue(SpeakerAttribution.names(turns: turns, observations: Array(repeating: samples[0], count: 10), audioStartedAt: 100).isEmpty)
    }

    func testOverlapAndBoundarySamplesDoNotNameSpeakers() {
        let turns = [SpeakerTurn(speaker_id: "system_1", start: 0, end: 12), SpeakerTurn(speaker_id: "system_2", start: 1, end: 11)]
        let samples = [2.0, 4, 6].map { SpeakerObservation(observed_at: $0, meeting_id: "meet", names: ["Alice"]) }
        XCTAssertTrue(SpeakerAttribution.names(turns: turns, observations: samples, audioStartedAt: 0).isEmpty)
        let short = [SpeakerTurn(speaker_id: "a", start: 0, end: 0.5)]
        XCTAssertTrue(SpeakerAttribution.names(turns: short, observations: samples, audioStartedAt: 0).isEmpty)
    }

    func testConflictingNamesAndDuplicateDisplayNamesRemainUnknown() {
        let turns = [SpeakerTurn(speaker_id: "a", start: 0, end: 10), SpeakerTurn(speaker_id: "b", start: 12, end: 22)]
        let sameName = [2.0, 4, 6, 14, 16, 18].map { SpeakerObservation(observed_at: $0, meeting_id: "meet", names: ["Alice"]) }
        XCTAssertTrue(SpeakerAttribution.names(turns: turns, observations: sameName, audioStartedAt: 0).isEmpty)
        let conflict = sameName.prefix(3) + [SpeakerObservation(observed_at: 8, meeting_id: "meet", names: ["Bob"])]
        XCTAssertTrue(SpeakerAttribution.names(turns: turns, observations: Array(conflict), audioStartedAt: 0).isEmpty)
    }

    func testWordsSplitAtSpeakerChangesAndOffsetsAreAppliedOnce() {
        let segment = TranscriptSegment(start: 0, end: 4, text: "Hello there Hi Alice", words: [
            TranscriptWord(start: 0, end: 1, text: "Hello"), TranscriptWord(start: 1, end: 2, text: "there"),
            TranscriptWord(start: 2, end: 3, text: "Hi"), TranscriptWord(start: 3, end: 4, text: "Alice")])
        let turns = [SpeakerTurn(speaker_id: "system_1", start: 0, end: 2), SpeakerTurn(speaker_id: "system_2", start: 2, end: 4)]
        let result = SpeakerAttribution.align([segment], turns: turns, source: "system", offset: 0.15,
                                               namedSpans: [NamedSpeakerSpan(start: 0, end: 2, identity: SpeakerIdentity(name: "Bob", source: "meeting_ui", evidence_count: 3))])
        XCTAssertTrue(result[0].speaker.hasPrefix("system_name_"))
        XCTAssertEqual(result[1].speaker, "system_2")
        XCTAssertEqual(result.map(\.text), ["Hello there", "Hi Alice"])
        XCTAssertEqual(result[0].start_ms, 150)
        XCTAssertEqual(result[1].end_ms, 4150)
        XCTAssertEqual(result[0].speaker_name, "Bob")
        XCTAssertNil(result[1].speaker_name)
    }

    func testOverlapAndMissingWordTimingsDoNotAssignMajoritySpeaker() {
        let turns = [SpeakerTurn(speaker_id: "a", start: 0, end: 8), SpeakerTurn(speaker_id: "b", start: 8, end: 10)]
        let segment = TranscriptSegment(start: 0, end: 10, text: "Two people in one sentence")
        let result = SpeakerAttribution.align([segment], turns: turns, source: "system", offset: 0, namedSpans: [])
        XCTAssertEqual(result[0].speaker, "system_unknown")
        XCTAssertEqual(result[0].text, segment.text)
        XCTAssertNil(SpeakerAttribution.speaker(start: 0, end: 1, turns: [
            SpeakerTurn(speaker_id: "a", start: 0, end: 1), SpeakerTurn(speaker_id: "b", start: 0.5, end: 1)]))
    }

    func testOnlyExplicitActivityLabelsCount() {
        XCTAssertEqual(SpeakerEvidence.activeName(label: "Alice is speaking", role: "AXGroup"), "Alice")
        XCTAssertEqual(SpeakerEvidence.activeName(label: "Speaking: Bob", role: "AXImage"), "Bob")
        XCTAssertEqual(SpeakerEvidence.activeName(label: "Dragoș vorbește", role: "AXGroup"), "Dragoș")
        for label in ["Alice, microphone on", "Alice, pinned", "Alice", "Alice is not speaking", "You is speaking", "Alice (You) is speaking"] {
            XCTAssertNil(SpeakerEvidence.activeName(label: label, role: "AXGroup"), label)
        }
        XCTAssertNil(SpeakerEvidence.activeName(label: "Alice is speaking", role: "AXStaticText"))
        XCTAssertNil(SpeakerAttribution.cleanName("Alice\nBob"))
    }

    func testLegacyTranscriptDecodesAndV2RoundTrips() throws {
        let json = #"{"engine":"parakeet","model":"test","created_at":"now","segments":[{"speaker":"me","start_ms":0,"end_ms":1000,"text":"Hello"}]}"#
        var transcript = try JSONDecoder().decode(Transcript.self, from: Data(json.utf8))
        XCTAssertNil(transcript.segments[0].speaker_name)
        transcript.schema_version = 2
        transcript.segments[0].speaker_name = "Dragos"
        let decoded = try JSONDecoder().decode(Transcript.self, from: JSONEncoder().encode(transcript))
        XCTAssertEqual(decoded.segments[0].speaker_name, "Dragos")
        XCTAssertEqual(decoded.segments[0].speaker, "me")
    }
}

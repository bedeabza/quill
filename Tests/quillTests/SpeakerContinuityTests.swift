import XCTest
@testable import quill

final class SpeakerContinuityTests: XCTestCase {
    func testEstablishedVoiceNameSurvivesLongLaterUIGap() {
        let turns = [SpeakerTurn(speaker_id: "voice", start: 0, end: 20),
                     SpeakerTurn(speaker_id: "voice", start: 30, end: 50),
                     SpeakerTurn(speaker_id: "voice", start: 100, end: 1000)]
        let anchors = [NamedSpeakerSpan(start: 1, end: 9, identity: .init(name: "Mihai", source: "meeting_tile", evidence_count: 30)),
                       NamedSpeakerSpan(start: 31, end: 39, identity: .init(name: "Mihai", source: "meeting_tile", evidence_count: 30))]
        let learned = SpeakerAttribution.voiceNames(turns: turns, spans: anchors)
        XCTAssertEqual(learned["voice"]?.name, "Mihai")
        XCTAssertEqual(SpeakerAttribution.resolvedIdentity(start: 800, end: 801, turns: turns, spans: anchors, voiceNames: learned)?.name, "Mihai")
    }

    private func span(_ name: String, _ start: Double, _ end: Double, source: String = "meeting_tile") -> NamedSpeakerSpan {
        NamedSpeakerSpan(start: start, end: end, identity: SpeakerIdentity(name: name, source: source, evidence_count: 20))
    }

    private var turns: [SpeakerTurn] {
        [.init(speaker_id: "a", start: 0, end: 12), .init(speaker_id: "a", start: 20, end: 32)]
    }

    private var anchors: [NamedSpeakerSpan] { [span("Alice", 1, 8), span("Alice", 21, 28)] }

    func testVerifiedVoiceKeepsItsNameThroughMissingTileSamples() throws {
        let learned = SpeakerAttribution.voiceNames(turns: turns, spans: anchors)
        XCTAssertEqual(learned["a"]?.name, "Alice")
        let segment = TranscriptSegment(start: 7.5, end: 10, text: "Still the same speaker", words: [
            .init(start: 7.5, end: 7.8, text: "Still"), .init(start: 8.1, end: 8.4, text: "the"),
            .init(start: 8.5, end: 9, text: "same"), .init(start: 9.5, end: 10, text: "speaker")])
        let output = SpeakerAttribution.align([segment], turns: turns, source: "system", offset: 0.25, namedSpans: anchors)
        XCTAssertEqual(output.count, 1)
        XCTAssertEqual(output.first?.speaker_name, "Alice")
        XCTAssertEqual(output.first?.attribution, "meeting_voice")
        XCTAssertEqual(output.first?.text, segment.text)
        XCTAssertEqual(output.first?.start_ms, 7750)
        XCTAssertEqual(output.first?.end_ms, 10250)
    }

    func testShortGapsBetweenSameNameSpansCountTogetherWithoutDoubleCounting() {
        let names = [span("Alice", 0, 0.4), span("Alice", 0.4, 0.8)]
        XCTAssertEqual(SpeakerAttribution.resolvedIdentity(start: 0, end: 1, turns: [], spans: names, voiceNames: [:])?.name, "Alice")
        let repeated = Array(repeating: span("Alice", 0, 0.2), count: 20)
        XCTAssertNil(SpeakerAttribution.resolvedIdentity(start: 0, end: 1, turns: [], spans: repeated, voiceNames: [:]))
    }

    func testCaptionsCannotTeachAWholeVoiceCluster() {
        let captions = anchors.map { span($0.identity.name, $0.start, $0.end, source: "meeting_caption") }
        XCTAssertTrue(SpeakerAttribution.voiceNames(turns: turns, spans: captions).isEmpty)
    }

    func testBriefOrDuplicateAnchorsCannotTeachACluster() {
        XCTAssertTrue(SpeakerAttribution.voiceNames(turns: turns, spans: Array(repeating: span("Alice", 1, 2), count: 50)).isEmpty)
        XCTAssertTrue(SpeakerAttribution.voiceNames(turns: [turns[0]], spans: [span("Alice", 0, 12)]).isEmpty)
    }

    func testMinoritySpeakerBlocksAContaminatedClusterEvenWithHugeMajority() {
        let turns = [SpeakerTurn(speaker_id: "a", start: 0, end: 100),
                     SpeakerTurn(speaker_id: "a", start: 200, end: 300),
                     SpeakerTurn(speaker_id: "a", start: 400, end: 405)]
        let spans = [span("Alice", 1, 99), span("Alice", 201, 299), span("Bob", 401, 404)]
        XCTAssertTrue(SpeakerAttribution.voiceNames(turns: turns, spans: spans).isEmpty)
    }

    func testSplitClustersCanShareOneIndependentlyVerifiedName() {
        let other = [SpeakerTurn(speaker_id: "b", start: 40, end: 52), SpeakerTurn(speaker_id: "b", start: 60, end: 72)]
        let names = SpeakerAttribution.voiceNames(turns: turns + other, spans: anchors + [span("Alice", 41, 48), span("Alice", 61, 68)])
        XCTAssertEqual(names["a"]?.name, "Alice")
        XCTAssertEqual(names["b"]?.name, "Alice")
    }

    func testConflictingLiveNameOverridesOrBlocksLearnedName() {
        let names = SpeakerAttribution.voiceNames(turns: turns, spans: anchors)
        XCTAssertEqual(SpeakerAttribution.resolvedIdentity(start: 9, end: 10, turns: turns,
            spans: [span("Bob", 9, 10)], voiceNames: names)?.name, "Bob")
        XCTAssertNil(SpeakerAttribution.resolvedIdentity(start: 9, end: 10, turns: turns,
            spans: [span("Bob", 9.3, 9.6)], voiceNames: names))
    }

    func testZeroLengthWordCanUseLiveEvidenceWithoutMovingItsTimestamp() {
        let segment = TranscriptSegment(start: 5, end: 5, text: "Yes.", words: [.init(start: 5, end: 5, text: "Yes.")])
        let result = SpeakerAttribution.align([segment], turns: [], source: "system", offset: 0,
                                              namedSpans: [span("Alice", 4, 6)])
        XCTAssertEqual(result.first?.speaker_name, "Alice")
        XCTAssertEqual(result.first?.start_ms, 5000)
        XCTAssertEqual(result.first?.end_ms, 5000)
    }

    func testSilenceInLongWordDoesNotDefeatConsistentVoiceEvidence() {
        let name = SpeakerIdentity(name: "Alice", source: "meeting_voice", evidence_count: 10)
        let turns = [SpeakerTurn(speaker_id: "a", start: 2, end: 3), SpeakerTurn(speaker_id: "b", start: 5, end: 6)]
        XCTAssertEqual(SpeakerAttribution.resolvedIdentity(start: 0, end: 10, turns: turns,
            spans: [], voiceNames: ["a": name, "b": name])?.name, "Alice")
        XCTAssertNil(SpeakerAttribution.resolvedIdentity(start: 0, end: 10, turns: turns,
            spans: [], voiceNames: ["a": name]))
        XCTAssertNil(SpeakerAttribution.resolvedIdentity(start: 0, end: 31, turns: turns,
            spans: [], voiceNames: ["a": name, "b": name]))
    }

    func testOverlappingDifferentVoicesAndUnobservedVoicesRemainUnknown() {
        let names = ["a": SpeakerIdentity(name: "Alice", source: "meeting_voice", evidence_count: 10),
                     "b": SpeakerIdentity(name: "Bob", source: "meeting_voice", evidence_count: 10)]
        let overlap = [SpeakerTurn(speaker_id: "a", start: 0, end: 3), SpeakerTurn(speaker_id: "b", start: 1, end: 4)]
        XCTAssertNil(SpeakerAttribution.resolvedIdentity(start: 1, end: 2, turns: overlap, spans: [], voiceNames: names))
        XCTAssertNil(SpeakerAttribution.resolvedIdentity(start: 10, end: 11, turns: overlap, spans: [], voiceNames: names))
    }

    func testShortReplyCanUseDelayedSustainedTileButNotDistantOrCompetingTiles() {
        let delayed = [span("Alice", 1.4, 3)]
        XCTAssertEqual(SpeakerAttribution.resolvedIdentity(start: 1, end: 1.2, turns: [], spans: delayed, voiceNames: [:])?.source, "meeting_tile_edge")
        XCTAssertNil(SpeakerAttribution.resolvedIdentity(start: 0, end: 0.2, turns: [], spans: delayed, voiceNames: [:]))
        XCTAssertNil(SpeakerAttribution.resolvedIdentity(start: 0, end: 1.2, turns: [], spans: delayed, voiceNames: [:]))
        XCTAssertNil(SpeakerAttribution.resolvedIdentity(start: 1, end: 1.2, turns: [], spans: delayed + [span("Bob", 0.5, 1)], voiceNames: [:]))
        let overlap = [SpeakerTurn(speaker_id: "a", start: 1, end: 2), SpeakerTurn(speaker_id: "b", start: 1, end: 2)]
        XCTAssertNil(SpeakerAttribution.resolvedIdentity(start: 1, end: 1.2, turns: overlap, spans: delayed, voiceNames: [:]))
    }

    func testConflictingKnownVoiceDoesNotReappearAsAnonymousSpeakerNumber() {
        let voice = SpeakerIdentity(name: "Alice", source: "meeting_voice", evidence_count: 20)
        let word = TranscriptWord(start: 9, end: 10, text: "Uncertain")
        let result = SpeakerAttribution.align([TranscriptSegment(start: 9, end: 10, text: word.text, words: [word])],
            turns: turns, source: "system", offset: 0, namedSpans: [span("Bob", 9.3, 9.6)], voiceIdentities: ["a": voice])
        XCTAssertEqual(result.first?.speaker, "system_unknown")
        XCTAssertNil(result.first?.speaker_name)
    }
}

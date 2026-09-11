import XCTest
@testable import quill

final class MeetTileEvidenceTests: XCTestCase {
    func testCapturedBraveTileStates() throws {
        guard let path = ProcessInfo.processInfo.environment["QUILL_TEST_TILE_CAPTURE"] else {
            throw XCTSkip("Set QUILL_TEST_TILE_CAPTURE to the local live tile diagnostic capture")
        }
        let lines = try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n")
        var states: Set<String> = []
        for line in lines {
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            let meetings = try XCTUnwrap(json["speaker_boxes"] as? [String: [[String: String]]])
            for raw in meetings.values where !raw.isEmpty {
                let nodes = raw.map { SpeakerUINode(parent: $0["parent"].flatMap(Int.init), role: $0["role"] ?? "", text: $0["text"] ?? "",
                                                    classes: Set(($0["classes"] ?? "").split(separator: " ").map(String.init))) }
                let tiles = MeetTileEvidence.tiles(nodes)
                XCTAssertEqual(tiles.count, 2)
                XCTAssertEqual(tiles.filter(\.isLocal).count, 1)
                for tile in tiles where MeetTileEvidence.isSpeaking(classes: nodes[tile.indicatorIndex].classes) {
                    states.insert(tile.isLocal ? "local" : "remote")
                }
            }
        }
        XCTAssertEqual(states, ["local", "remote"])
    }

    private func node(_ parent: Int?, _ classes: String = "", text: String = "", role: String = "AXGroup") -> SpeakerUINode {
        SpeakerUINode(parent: parent, role: role, text: text, classes: Set(classes.split(separator: " ").map(String.init)))
    }

    func testLiveMeetStructureAssociatesActivityWithTheCorrectTile() {
        // Structure/classes from the live Brave call, with synthetic names.
        let nodes = [node(nil), node(0), node(1, "OFfHfd urlhDe iPFm3e"),
                     node(2), node(3, text: "Participant A", role: "AXStaticText"),
                     node(1, "lH9pqf atLQQ iPFm3e kssMZb"),
                     node(0), node(6, "OFfHfd urlhDe eQJ1qd"), node(7),
                     node(8, text: "Participant B", role: "AXStaticText"),
                     node(6, "lH9pqf atLQQ eQJ1qd")]
        let tiles = MeetTileEvidence.tiles(nodes)
        XCTAssertEqual(tiles.map(\.name), ["Participant A", "Participant B"])
        XCTAssertEqual(tiles.map(\.isLocal), [false, true])
        XCTAssertEqual(tiles.map { MeetTileEvidence.isSpeaking(classes: nodes[$0.indicatorIndex].classes) }, [true, false])
    }

    func testRosterNamesAndUnrecognizedMarkupCannotBecomeSpeakingEvidence() {
        XCTAssertTrue(MeetTileEvidence.tiles([node(nil), node(0, "cxdMu KV1GEc", text: "Alice"),
                                             node(1, text: "Alice", role: "AXStaticText")]).isEmpty)
        XCTAssertFalse(MeetTileEvidence.isSpeaking(classes: ["lH9pqf", "atLQQ"]))
        XCTAssertFalse(MeetTileEvidence.isSpeaking(classes: ["kssMZb"]))
        let ambiguous = [node(nil), node(0, "OFfHfd"), node(1, text: "Alice", role: "AXStaticText"),
                         node(1, text: "Bob", role: "AXStaticText"), node(0, "lH9pqf atLQQ kssMZb")]
        XCTAssertTrue(MeetTileEvidence.tiles(ambiguous).isEmpty)
    }

    func testTileNamesDoNotDependOnTranscriptLanguageOrAcousticClusters() {
        let observations = [0.0, 0.25, 0.5, 0.75].map {
            SpeakerObservation(observed_at: 100 + $0, meeting_id: "meet", names: ["Alice"], source: "meeting_tile")
        } + [SpeakerObservation(observed_at: 101, meeting_id: "meet", names: [], source: "meeting_tile")]
          + [1.25, 1.5, 1.75, 2.0].map {
            SpeakerObservation(observed_at: 100 + $0, meeting_id: "meet", names: ["Bob"], source: "meeting_tile")
        }
        let spans = SpeakerAttribution.tileSpans(observations: observations, audioStartedAt: 100)
        XCTAssertEqual(spans.map { $0.identity.name }, ["Alice", "Bob"])
        let words = [TranscriptWord(start: 0.3, end: 0.6, text: "Bună"), TranscriptWord(start: 1.5, end: 1.8, text: "Hello")]
        let segments = words.map { TranscriptSegment(start: $0.start, end: $0.end, text: $0.text, words: [$0]) }
        let result = SpeakerAttribution.align(segments, turns: [SpeakerTurn(speaker_id: "system_1", start: 0, end: 3)],
                                               source: "system", offset: 0, namedSpans: spans)
        XCTAssertEqual(result.map(\.speaker_name), ["Alice", "Bob"])
        XCTAssertEqual(result.map(\.attribution), ["meeting_tile", "meeting_tile"])
        XCTAssertNotEqual(result[0].speaker, result[1].speaker)
    }

    func testMissingAmbiguousAndSingleFrameStatesDoNotCreateNames() {
        let samples = [0.0, 2.0, 4.0].map { SpeakerObservation(observed_at: 100 + $0, meeting_id: "meet", names: ["Alice"], source: "meeting_tile") }
        XCTAssertTrue(SpeakerAttribution.tileSpans(observations: samples, audioStartedAt: 100).isEmpty)
        let ambiguous = [0.0, 0.25, 0.5].map { SpeakerObservation(observed_at: 100 + $0, meeting_id: "meet", names: ["Alice", "Bob"], source: "meeting_tile") }
        XCTAssertTrue(SpeakerAttribution.tileSpans(observations: ambiguous, audioStartedAt: 100).isEmpty)
        let repeated = Array(repeating: samples[0], count: 10)
        XCTAssertTrue(SpeakerAttribution.tileSpans(observations: repeated, audioStartedAt: 100).isEmpty)
    }

    func testBoundaryRepairCannotBridgeDifferentVoicesOrLongGaps() {
        let alice = SpeakerTurn(speaker_id: "a", start: 2, end: 4)
        XCTAssertEqual(SpeakerAttribution.speaker(start: 1.5, end: 1.8, turns: [alice]), "a")
        XCTAssertNil(SpeakerAttribution.speaker(start: 0, end: 0.3, turns: [alice]))
        XCTAssertNil(SpeakerAttribution.speaker(start: 1.5, end: 1.8, turns: [alice, SpeakerTurn(speaker_id: "b", start: 0, end: 1.5)]))
        XCTAssertNil(SpeakerAttribution.speaker(start: 0, end: 20, turns: [alice]))
    }

    func testLateParticipantWithWrappedIndicatorKeepsOwnName() {
        var nodes = [node(nil), node(0), node(1, "OFfHfd"),
                     node(2, text: "Alice", role: "AXStaticText"), node(1, "lH9pqf atLQQ")]
        XCTAssertEqual(MeetTileEvidence.tiles(nodes).map(\.name), ["Alice"])
        nodes += [node(0), node(5, "OFfHfd"), node(6, text: "Bob", role: "AXStaticText"),
                  node(5), node(8, "lH9pqf atLQQ kssMZb")]
        let tiles = MeetTileEvidence.tiles(nodes)
        XCTAssertEqual(tiles.map(\.name), ["Alice", "Bob"])
        XCTAssertEqual(tiles.filter { $0.kind.isSpeaking(nodes[$0.indicatorIndex].classes) }.map(\.name), ["Bob"])
    }

    func testMissingNameCannotBorrowAnotherParticipantsLabel() {
        let nodes = [node(nil), node(0), node(1, "OFfHfd"), node(2, text: "Alice", role: "AXStaticText"),
                     node(1, "lH9pqf atLQQ"), node(0), node(5), node(6, "lH9pqf atLQQ kssMZb")]
        XCTAssertEqual(MeetTileEvidence.tiles(nodes).map(\.name), ["Alice"])
    }

    func testNewNameLateInMeetingDoesNotRenameEarlierUnknownVoice() {
        let samples = [120.0, 120.25, 120.5, 120.75].map {
            SpeakerObservation(observed_at: 1000 + $0, meeting_id: "meet", names: ["Late arrival"], source: "meeting_tile")
        }
        let segments = [10.25, 120.25].map {
            TranscriptSegment(start: $0, end: $0 + 0.2, text: "Hello", words: [TranscriptWord(start: $0, end: $0 + 0.2, text: "Hello")])
        }
        let result = SpeakerAttribution.align(segments, turns: [SpeakerTurn(speaker_id: "system_1", start: 0, end: 130)],
                                               source: "system", offset: 0,
                                               namedSpans: SpeakerAttribution.tileSpans(observations: samples, audioStartedAt: 1000))
        XCTAssertNil(result[0].speaker_name)
        XCTAssertEqual(result[1].speaker_name, "Late arrival")
    }

    func testConfiguredLocalNameIsExcludedWithoutSelfTileClass() {
        XCTAssertTrue(SpeakerAttribution.isLocalName("  Dragos Badea ", localName: "Dragos Badea"))
        XCTAssertTrue(SpeakerAttribution.isLocalName("DRAGOS BADEA", localName: "Dragos Badea"))
        XCTAssertFalse(SpeakerAttribution.isLocalName("Dragos Badea Jr", localName: "Dragos Badea"))
        XCTAssertFalse(SpeakerAttribution.isLocalName("Alice", localName: nil))
    }
}

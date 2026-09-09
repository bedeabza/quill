import XCTest
@testable import quill

final class TeamsTileEvidenceTests: XCTestCase {
    private func fixture(active: Bool = false) -> [SpeakerUINode] {
        [SpeakerUINode(parent: nil, role: "AXGroup", text: "", classes: []),
         SpeakerUINode(parent: 0, role: "AXImage", text: "Myself video, Local Person, Unmuted, video is on", classes: ["fui-Primitive"]),
         SpeakerUINode(parent: 0, role: "AXMenuItem", text: "Remote Person Unverified, video is on, Context menu is available", classes: ["fui-Flex"]),
         SpeakerUINode(parent: 2, role: "AXGroup", text: "", classes: ["fui-Flex", "vdi-occlusion"]),
         SpeakerUINode(parent: 3, role: "AXStaticText", text: "Remote Person", classes: []),
         SpeakerUINode(parent: 2, role: "AXGroup", text: "", classes: active ? ["fui-Flex", "vdi-frame-occlusion"] : ["fui-Flex"], subrole: "AXEmptyGroup")]
    }

    func testNativeTeamsFrameBindsOnlyTheRemoteName() {
        for active in [false, true] {
            let nodes = fixture(active: active)
            let tiles = TeamsTileEvidence.tiles(nodes)
            XCTAssertEqual(tiles.count, 1)
            XCTAssertEqual(tiles.first?.name, "Remote Person")
            XCTAssertEqual(tiles.first?.isLocal, false)
            XCTAssertEqual(tiles.first?.kind.isSpeaking(nodes[5].classes), active)
        }
    }

    func testRosterAndAmbiguousFramesAreRejected() {
        XCTAssertTrue(TeamsTileEvidence.tiles([SpeakerUINode(parent: nil, role: "AXRow", text: "Remote Person, unmuted", classes: ["fui-Flex"])]).isEmpty)
        var nodes = fixture()
        nodes.append(SpeakerUINode(parent: 2, role: "AXGroup", text: "", classes: ["fui-Flex"], subrole: "AXEmptyGroup"))
        XCTAssertTrue(TeamsTileEvidence.tiles(nodes).isEmpty)
        let pinned = [SpeakerUINode(parent: nil, role: "AXMenuItem", text: "Remote Person, pinned, Context menu is available", classes: ["fui-Flex"])]
        XCTAssertTrue(TeamsTileEvidence.tiles(pinned).isEmpty)
    }

    func testActualTeamsDesktopSpeakingAndSilentFrames() throws {
        guard let path = ProcessInfo.processInfo.environment["QUILL_TEST_TEAMS_CAPTURE"] else {
            throw XCTSkip("Set QUILL_TEST_TEAMS_CAPTURE to the local native Teams diagnostic capture")
        }
        let lines = try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n")
        var states: Set<Bool> = []
        for line in lines {
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            let meetings = try XCTUnwrap(object["speaker_boxes"] as? [String: [[String: String]]])
            for raw in meetings.values where !raw.isEmpty {
                let nodes = raw.map { SpeakerUINode(parent: $0["parent"].flatMap(Int.init), role: $0["role"] ?? "", text: $0["text"] ?? "",
                                                   classes: Set(($0["classes"] ?? "").split(separator: " ").map(String.init)), subrole: $0["subrole"] ?? "") }
                let tiles = TeamsTileEvidence.tiles(nodes)
                XCTAssertEqual(tiles.count, 1)
                for tile in tiles { states.insert(tile.kind.isSpeaking(nodes[tile.indicatorIndex].classes)) }
            }
        }
        XCTAssertEqual(states, [false, true])
    }
}

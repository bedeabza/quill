import XCTest
@testable import quill

final class SlackTileEvidenceTests: XCTestCase {
    // Structure and classes captured from the native Slack test huddle. Names
    // are replaced with fixtures; both native and web use this peer grid.
    private func grid() -> [SpeakerUINode] {
        [.init(parent: nil, role: "AXTable", text: "", classes: ["p-huddle_grid_component"]),
         .init(parent: 0, role: "AXGroup", text: "", classes: ["p-huddle_grid_component__grid"]),
         .init(parent: 1, role: "AXRow", text: "View Alice's profile View Bob's profile", classes: ["p-bp__grid_row", "offscreen"]),
         .init(parent: 2, role: "AXCell", text: "View Alice's profile", classes: ["p-huddle_peer_tile"]),
         .init(parent: 3, role: "AXGroup", text: "", classes: ["p-calls_video", "p-huddle_peer_tile__video", "flipped"]),
         .init(parent: 2, role: "AXCell", text: "View Bob's profile", classes: ["p-huddle_peer_tile"]),
         .init(parent: 5, role: "AXGroup", text: "", classes: ["p-calls_video", "p-huddle_peer_tile__video"])]
    }

    private func overlay(parent: Int, active: Bool = true) -> SpeakerUINode {
        .init(parent: parent, role: "AXGroup", text: "", classes: ["p-huddle_peer_tile__mic_overlay",
            active ? "p-huddle_peer_tile__overlay--active_speaker" : "p-huddle_peer_tile__overlay--muted"])
    }

    private func activity(_ nodes: [SpeakerUINode], root: Int, name: String) -> Bool? {
        SlackTileEvidence.activity(root: root, expectedName: name, hasTime: { true }) { index in
            guard nodes.indices.contains(index) else { return nil }
            return (nodes[index], nodes.indices.filter { nodes[$0].parent == index })
        }
    }

    func testCapturedPeerNamesAndSpeakingTransitions() {
        var nodes = grid()
        let tiles = SlackTileEvidence.tiles(nodes)
        XCTAssertEqual(tiles.map(\.name), ["Alice", "Bob"])
        XCTAssertEqual(tiles.map(\.indicatorIndex), [3, 5], "Cache stable peer cells, not transient overlays")
        XCTAssertEqual(activity(nodes, root: 5, name: "Bob"), false)
        nodes.append(overlay(parent: 5))
        XCTAssertEqual(activity(nodes, root: 5, name: "Bob"), true)
        XCTAssertEqual(activity(nodes, root: 3, name: "Alice"), false)
        nodes.removeLast()
        nodes.append(overlay(parent: 3))
        XCTAssertEqual(activity(nodes, root: 5, name: "Bob"), false)
        XCTAssertEqual(activity(nodes, root: 3, name: "Alice"), true)
        nodes.removeLast()
        XCTAssertEqual(activity(nodes, root: 3, name: "Alice"), false)
    }

    func testBrowserDocumentKeepsProfileLinksAndChatOutsideThePeerGrid() {
        let web = SpeakerUINode(parent: nil, role: "AXWebArea", text: "Slack", classes: [])
        var nodes = [web] + grid().map { node in
            SpeakerUINode(parent: node.parent.map { $0 + 1 } ?? 0, role: node.role, text: node.text, classes: node.classes)
        }
        nodes.append(.init(parent: 0, role: "AXButton", text: "View Unrelated's profile", classes: []))
        nodes.append(.init(parent: 0, role: "AXCell", text: "View Chat Person's profile", classes: ["p-huddle_peer_tile"]))
        nodes.append(.init(parent: 0, role: "AXStaticText", text: "Mallory is speaking", classes: []))
        XCTAssertEqual(SlackTileEvidence.tiles(nodes).map(\.name), ["Alice", "Bob"])
    }

    func testProfileLabelsAreParsedExactlyAndSupportApostrophes() {
        XCTAssertEqual(SlackTileEvidence.name(in: "View Bob O'Neil's profile"), "Bob O'Neil")
        XCTAssertEqual(SlackTileEvidence.name(in: "View Emil’s profile"), "Emil")
        for label in ["Alice", "View profile", "View You's profile", "View Alice's profile later", "View Alice\nBob's profile"] {
            XCTAssertNil(SlackTileEvidence.name(in: label), label)
        }
    }

    func testSilentRosterExcludesSelfAndDoesNotInventACompleteHeadcount() {
        let members = ParticipantEvidence.members(grid(), service: "Slack", localName: "Alice")
        XCTAssertEqual(members, [.init(name: "Alice", is_local: true), .init(name: "Bob", is_local: false)])
        var roster = ParticipantRoster(audio_started_at: 1000)
        for time in [1000.0, 1002.0] {
            roster.observe(.init(observed_at: time, meeting_id: "slack", names: [], source: "meeting_roster",
                participants: members, participant_count: nil, roster_complete: false), localName: "Alice")
        }
        XCTAssertEqual(roster.participants.map(\.name), ["Alice", "Bob"])
        XCTAssertNil(roster.soleRemoteIdentity(startMS: 0, endMS: 1000))
    }

    func testMuteVideoAndPinnedStateAreNotSpeakingEvidence() {
        var nodes = grid()
        nodes.append(overlay(parent: 5, active: false))
        nodes.append(.init(parent: 5, role: "AXGroup", text: "", classes: ["p-huddle_peer_tile__overlay--active_speaker"]))
        nodes.append(.init(parent: 5, role: "AXGroup", text: "", classes: ["p-huddle_peer_tile--pinned", "unmuted"]))
        XCTAssertEqual(activity(nodes, root: 5, name: "Bob"), false)
    }

    func testRenamedRecycledOrMissingPeersCannotKeepOldNames() {
        var nodes = grid()
        nodes[5] = .init(parent: 2, role: "AXCell", text: "View Charlie's profile", classes: ["p-huddle_peer_tile"])
        nodes.append(overlay(parent: 5))
        XCTAssertNil(activity(nodes, root: 5, name: "Bob"))
        XCTAssertEqual(SlackTileEvidence.tiles(nodes).map(\.name), ["Alice", "Charlie"])
        XCTAssertNil(activity(nodes, root: 99, name: "Bob"))
        nodes[5] = .init(parent: 2, role: "AXCell", text: "View Bob's profile", classes: ["new-unknown-layout"])
        XCTAssertNil(activity(nodes, root: 5, name: "Bob"))
    }

    func testPeerRenameDuringSampleIsRejected() {
        let nodes = grid()
        var rootReads = 0
        let result = SlackTileEvidence.activity(root: 5, expectedName: "Bob", hasTime: { true }) { index in
            if index == 5 {
                rootReads += 1
                if rootReads > 1 {
                    return (SpeakerUINode(parent: 2, role: "AXCell", text: "View Charlie's profile", classes: ["p-huddle_peer_tile"]), [])
                }
            }
            return (nodes[index], nodes.indices.filter { nodes[$0].parent == index })
        }
        XCTAssertNil(result)
    }

    func testDuplicateNamesAndNestedPeersAreAmbiguous() {
        var nodes = grid()
        nodes[5] = .init(parent: 2, role: "AXCell", text: "View ALICE's profile", classes: ["p-huddle_peer_tile"])
        XCTAssertTrue(SlackTileEvidence.tiles(nodes).isEmpty)
        nodes = grid()
        nodes.append(.init(parent: 5, role: "AXCell", text: "View Charlie's profile", classes: ["p-huddle_peer_tile"]))
        nodes.append(overlay(parent: 7))
        XCTAssertNil(activity(nodes, root: 5, name: "Bob"))
        XCTAssertEqual(SlackTileEvidence.tiles(nodes).map(\.name), ["Alice", "Bob"])
    }

    func testIncompleteSlowAndOversizedReadsReturnUnknown() {
        let nodes = grid()
        XCTAssertNil(SlackTileEvidence.activity(root: 5, expectedName: "Bob", hasTime: { false }) { index in (nodes[index], []) })
        XCTAssertNil(SlackTileEvidence.activity(root: 5, expectedName: "Bob", hasTime: { true }) { index in
            index == 5 ? (nodes[index], [99]) : nil
        })
        var large = grid()
        for _ in 0..<70 { large.append(.init(parent: 5, role: "AXGroup", text: "", classes: [])) }
        XCTAssertNil(activity(large, root: 5, name: "Bob"))
    }
}

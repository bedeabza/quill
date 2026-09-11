import XCTest
@testable import quill

final class SpeakerTreeRefreshTests: XCTestCase {
    private func node(_ parent: Int?, text: String = "") -> SpeakerUINode {
        SpeakerUINode(parent: parent, role: "AXGroup", text: text, classes: [])
    }

    func testLateArrivalRenameAndDepartureAreRediscovered() throws {
        var refresh = SpeakerTreeRefresh<Int>()
        var participants = [1: "Alice"]
        func read(_ element: Int, _ parent: Int?) -> (SpeakerUINode, [Int])? {
            (node(parent, text: participants[element] ?? ""), element == 0 ? participants.keys.sorted() : [])
        }
        let initial = try XCTUnwrap(refresh.step(root: 0, now: 100, hasTime: { true }, read: read))
        XCTAssertEqual(initial.map(\.node.text), ["", "Alice"])
        participants[2] = "Bob"
        XCTAssertNil(refresh.step(root: 0, now: 101, hasTime: { true }, read: read))
        let joined = try XCTUnwrap(refresh.step(root: 0, now: 102, hasTime: { true }, read: read))
        XCTAssertEqual(joined.map(\.node.text), ["", "Alice", "Bob"])
        participants[2] = "Robert"
        participants.removeValue(forKey: 1)
        let changed = try XCTUnwrap(refresh.step(root: 0, now: 104, hasTime: { true }, read: read))
        XCTAssertEqual(changed.map(\.node.text), ["", "Robert"])
    }

    func testLargeTreeResumesUntilLateTileBeyondOldNodeLimitIsReached() throws {
        var refresh = SpeakerTreeRefresh<Int>()
        var result: [SpeakerTreeRefresh<Int>.Entry]?
        var calls = 0
        for tick in 0..<80 {
            result = refresh.step(root: 0, now: Double(tick) * 0.25, hasTime: { true }) { element, parent in
                calls += 1
                return (self.node(parent, text: element == 4000 ? "Late arrival" : ""), element < 4000 ? [element + 1] : [])
            }
            if result != nil { break }
        }
        let snapshot = try XCTUnwrap(result)
        XCTAssertEqual(snapshot.count, 4001)
        XCTAssertEqual(snapshot.last?.node.text, "Late arrival")
        XCTAssertEqual(snapshot.last?.node.parent, 3999)
        XCTAssertEqual(calls, 4001, "Each chunk must continue instead of rereading the root")
    }

    func testTimeBudgetNeverPublishesPartialTree() {
        var refresh = SpeakerTreeRefresh<Int>()
        var reads = 0
        let partial = refresh.step(root: 0, now: 100, hasTime: { reads < 2 }) { element, parent in
            reads += 1
            return (self.node(parent), element == 0 ? [1, 2] : [])
        }
        XCTAssertNil(partial)
        XCTAssertFalse(refresh.isFresh(at: 100))
        let complete = refresh.step(root: 0, now: 100.25, hasTime: { true }) { _, parent in (self.node(parent), []) }
        XCTAssertEqual(complete?.count, 3)
        XCTAssertTrue(refresh.isFresh(at: 100.25))
        XCTAssertFalse(refresh.isFresh(at: 116))
    }

    func testDestroyedElementInvalidatesCacheAndRetries() {
        var refresh = SpeakerTreeRefresh<Int>()
        XCTAssertNotNil(refresh.step(root: 0, now: 100, hasTime: { true }) { _, parent in (self.node(parent), []) })
        XCTAssertNil(refresh.step(root: 0, now: 102, hasTime: { true }) { _, _ in nil })
        XCTAssertFalse(refresh.isFresh(at: 102))
        XCTAssertNotNil(refresh.step(root: 0, now: 102.5, hasTime: { true }) { _, parent in (self.node(parent), []) })
    }

    func testChangedMeetingDocumentDiscardsPendingOldNames() throws {
        var refresh = SpeakerTreeRefresh<Int>()
        var reads = 0
        XCTAssertNil(refresh.step(root: 0, now: 100, hasTime: { reads < 1 }) { _, parent in
            reads += 1
            return (self.node(parent, text: "Old meeting"), [1])
        })
        let changed = try XCTUnwrap(refresh.step(root: 2, now: 100.25, hasTime: { true }) { _, parent in
            (self.node(parent, text: "New meeting"), [])
        })
        XCTAssertEqual(changed.map(\.node.text), ["New meeting"])
    }

    func testInvalidationByChangedCachedNameBypassesPeriodicDelay() {
        var refresh = SpeakerTreeRefresh<Int>()
        XCTAssertNotNil(refresh.step(root: 0, now: 100, hasTime: { true }) { _, parent in (self.node(parent), []) })
        refresh.invalidate()
        XCTAssertFalse(refresh.isFresh(at: 100.1))
        XCTAssertNotNil(refresh.step(root: 0, now: 100.1, hasTime: { true }) { _, parent in (self.node(parent), []) })
    }

    func testStalledDiscoveryTimesOutAndCyclesAreBounded() {
        var refresh = SpeakerTreeRefresh<Int>()
        XCTAssertNil(refresh.step(root: 0, now: 100, hasTime: { false }) { _, _ in nil })
        XCTAssertNil(refresh.step(root: 0, now: 161, hasTime: { true }) { _, parent in (self.node(parent), []) })
        XCTAssertFalse(refresh.isFresh(at: 161))
        let result = refresh.step(root: 0, now: 162, hasTime: { true }) { _, parent in (self.node(parent), [0]) }
        XCTAssertEqual(result?.count, 1)
    }
}

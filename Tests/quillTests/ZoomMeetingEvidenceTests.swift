import XCTest
@testable import quill

final class ZoomMeetingEvidenceTests: XCTestCase {
    func testJoinedZoomCallIsRecognizedWhenToolbarIsHidden() {
        XCTAssertTrue(MeetingEvidence.isZoomConferenceWindow(title: "Zoom Meeting", videoLabels: ["Remote Person, Computer audio unmuted, Video on"]))
        XCTAssertTrue(MeetingEvidence.isZoomConferenceWindow(title: "Zoom Meeting", videoLabels: ["Remote Person, Phone audio muted, Video off"]))
    }

    func testPreviewSettingsAndArbitraryTitlesAreNotCalls() {
        let label = "Local Person, Computer audio unmuted, Video on"
        XCTAssertFalse(MeetingEvidence.isZoomConferenceWindow(title: "Video Preview", videoLabels: [label]))
        XCTAssertFalse(MeetingEvidence.isZoomConferenceWindow(title: "Settings", videoLabels: [label]))
        XCTAssertFalse(MeetingEvidence.isZoomConferenceWindow(title: "Zoom Meeting", videoLabels: []))
        XCTAssertFalse(MeetingEvidence.isZoomConferenceWindow(title: "Zoom Meeting", videoLabels: ["Zoom is ready"]))
    }
}

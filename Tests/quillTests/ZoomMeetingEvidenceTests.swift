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

    func testShareWindowsAreRecognizedButHomeShareButtonIsNot() {
        XCTAssertTrue(MeetingEvidence.isZoomShareWindow(title: "zoom share toolbar window", buttons: [], videoLabels: []))
        XCTAssertTrue(MeetingEvidence.isZoomShareWindow(title: "", buttons: ["Stop Share"], videoLabels: []))
        XCTAssertTrue(MeetingEvidence.isZoomShareWindow(title: "Zoom", buttons: [],
                                                        videoLabels: ["Remote Person, Computer audio unmuted, Video on"]))
        XCTAssertFalse(MeetingEvidence.isZoomShareWindow(title: "Zoom Workplace", buttons: ["New meeting", "Join", "Share screen"], videoLabels: []))
    }

    // 2026.11.11: sharing a screen hid the meeting window; three recordings lost
    // about two minutes each while Zoom kept its call audio running.
    func testSharingNeverEndsAnEstablishedZoomMeeting() {
        let zoom = DetectedMeeting(id: "19284:12", app: "zoom.us", service: "Zoom")
        XCTAssertEqual(MeetingEvidence.closedCallWindow(zoom, anotherCallWindow: false, zoomShareWindow: true, zoomAudioRunning: false), .present(zoom))
        XCTAssertEqual(MeetingEvidence.closedCallWindow(zoom, anotherCallWindow: false, zoomShareWindow: false, zoomAudioRunning: true), .unknown)
        XCTAssertEqual(MeetingEvidence.closedCallWindow(zoom, anotherCallWindow: false, zoomShareWindow: false, zoomAudioRunning: false), .ended)

        var policy = MeetingPolicy()
        policy.recordingStarted(for: zoom, automatic: true)
        for second in stride(from: 0, through: 170, by: 2) {
            XCTAssertNotEqual(policy.update([zoom.id: .unknown], now: Double(second)), .stop)
        }
        XCTAssertEqual(policy.update([zoom.id: .present(zoom)], now: 172), .none)
    }
}

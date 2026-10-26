import XCTest
@testable import quill

final class MeetingEvidenceTests: XCTestCase {
    func testEndedMeetingCannotRestartFromItsBackgroundTab() {
        var state = MeetingEndState()
        XCTAssertTrue(state.isEnded("meeting", endScreen: true, inCall: false))
        XCTAssertTrue(state.isEnded("meeting", endScreen: false, inCall: false))
        XCTAssertFalse(state.isEnded("meeting", endScreen: false, inCall: true))
    }

    func testOnlyRealMeetingHostsQualify() {
        XCTAssertEqual(MeetingEvidence.service(url: "https://meet.google.com/abc-defg-hij"), "Google Meet")
        XCTAssertNil(MeetingEvidence.service(url: "https://meet.google.com/"))
        XCTAssertNil(MeetingEvidence.service(url: "https://meet.google.com/?code=abc-defg-hij"))
        XCTAssertNil(MeetingEvidence.service(url: "file:///private/tmp/Meet-abc-defg-hij.html"))
        XCTAssertNil(MeetingEvidence.service(url: "https://meet.google.com.evil.test/abc-defg-hij"))
        XCTAssertNil(MeetingEvidence.service(url: "https://example.com/?meeting=teams.microsoft.com"))
        XCTAssertEqual(MeetingEvidence.service(url: "https://teams.cloud.microsoft/v2/"), "Microsoft Teams")
    }

    func testMeetPrefixedRoomURLs() {
        for path in ["meet/abc-defg-hij", "meet/abc-defg-hij/", "meet/abc-defg-hij?authuser=1"] {
            let url = "https://meet.google.com/" + path
            XCTAssertEqual(MeetingEvidence.service(url: url), "Google Meet")
            XCTAssertEqual(MeetingEvidence.meetCode(in: url), "abc-defg-hij")
        }
        for path in ["meet/", "meet/invalid", "meet/abc-defg-hij/extra", "other/abc-defg-hij"] {
            XCTAssertNil(MeetingEvidence.service(url: "https://meet.google.com/" + path))
        }
        XCTAssertNil(MeetingEvidence.service(url: "https://meet.google.com.evil.test/meet/abc-defg-hij"))
    }

    func testBackgroundMeetTabKeepsItsMeetingIdentity() {
        XCTAssertEqual(MeetingEvidence.meetCode(in: "Meet - abc-defg-hij"), "abc-defg-hij")
        XCTAssertEqual(MeetingEvidence.meetCode(in: "https://meet.google.com/abc-defg-hij?authuser=1"), "abc-defg-hij")
        XCTAssertNil(MeetingEvidence.meetCode(in: "A document about abc-defg-hij"))
    }

    func testLeaveControlsDoNotConfuseOrdinaryNavigation() {
        XCTAssertTrue(MeetingEvidence.isLeaveControl("Leave call"))
        XCTAssertTrue(MeetingEvidence.isLeaveControl("Leave call (Command + Shift + H)"))
        XCTAssertTrue(MeetingEvidence.isLeaveControl("Hang up"))
        XCTAssertFalse(MeetingEvidence.isLeaveControl("Leave a comment"))
        XCTAssertFalse(MeetingEvidence.isLeaveControl("End of document"))
    }

    func testOnlyExplicitMeetingEndMessagesQualify() {
        XCTAssertTrue(MeetingEvidence.isEndMessage("You left the meeting"))
        XCTAssertTrue(MeetingEvidence.isEndMessage("The meeting has ended."))
        XCTAssertFalse(MeetingEvidence.isEndMessage("Your microphone is muted"))
        XCTAssertFalse(MeetingEvidence.isEndMessage("No one else is here"))
        XCTAssertFalse(MeetingEvidence.isEndMessage("When the meeting has ended, close this tab"))
    }

    func testNativeLeaveRequiresOtherCallControls() {
        XCTAssertTrue(MeetingEvidence.hasCallControls(["Leave", "Mute microphone"]))
        XCTAssertTrue(MeetingEvidence.hasCallControls(["End", "Unmute"]))
        XCTAssertFalse(MeetingEvidence.hasCallControls(["Leave", "Calendar"]))
        XCTAssertFalse(MeetingEvidence.hasCallControls(["Mute notifications", "Chat"]))
    }
}

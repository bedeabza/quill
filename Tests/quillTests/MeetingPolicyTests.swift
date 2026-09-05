import XCTest
@testable import quill

final class MeetingPolicyTests: XCTestCase {
    let meeting = DetectedMeeting(id: "meet-1", app: "Brave", service: "Google Meet")

    func testPromptRequiresClickAndDoesNotRepeatAfterDismissal() {
        var policy = MeetingPolicy()
        XCTAssertEqual(policy.update([meeting.id: .present(meeting)], now: 0), .prompt(meeting))
        XCTAssertNil(policy.recordingMeeting)
        policy.dismissPrompt()
        XCTAssertEqual(policy.update([meeting.id: .present(meeting)], now: 50), .none)
    }

    func testStopsOnlyAfterContinuousConfirmedEnd() {
        var policy = MeetingPolicy()
        policy.recordingStarted(for: meeting)
        XCTAssertEqual(policy.update([meeting.id: .ended], now: 10), .countdown(30))
        XCTAssertEqual(policy.update([meeting.id: .ended], now: 39), .countdown(1))
        XCTAssertEqual(policy.update([meeting.id: .ended], now: 40), .stop)
    }

    func testUnknownAndResumedMeetingCancelCountdown() {
        var policy = MeetingPolicy()
        policy.recordingStarted(for: meeting)
        _ = policy.update([meeting.id: .ended], now: 0)
        XCTAssertEqual(policy.update([meeting.id: .unknown], now: 20), .unavailable)
        XCTAssertEqual(policy.update([meeting.id: .ended], now: 40), .countdown(30))
        XCTAssertEqual(policy.update([meeting.id: .present(meeting)], now: 50), .none)
        XCTAssertEqual(policy.update([meeting.id: .ended], now: 100), .countdown(30))
    }

    func testMissingObservationIsNotAnEndSignal() {
        var policy = MeetingPolicy()
        policy.recordingStarted(for: meeting)
        XCTAssertEqual(policy.update([:], now: 500), .unavailable)
    }

    func testManualRecordingBindsOnlyAnUnambiguousMeeting() {
        var policy = MeetingPolicy()
        policy.recordingStarted(for: nil)
        let other = DetectedMeeting(id: "zoom-1", app: "Zoom", service: "Zoom")
        XCTAssertEqual(policy.update([meeting.id: .present(meeting), other.id: .present(other)], now: 0), .none)
        XCTAssertNil(policy.recordingMeeting)
        _ = policy.update([meeting.id: .present(meeting)], now: 1)
        XCTAssertEqual(policy.recordingMeeting, meeting)
    }

    func testKeepRecordingDisablesAutoStopForThisRecording() {
        var policy = MeetingPolicy()
        policy.recordingStarted(for: meeting)
        policy.keepRecording()
        XCTAssertEqual(policy.update([meeting.id: .ended], now: 500), .none)
        XCTAssertNil(policy.recordingMeeting)
    }

    func testManualStopDoesNotPromptAgainForSameMeeting() {
        var policy = MeetingPolicy()
        policy.recordingStarted(for: meeting)
        policy.recordingStopped()
        XCTAssertEqual(policy.update([meeting.id: .present(meeting)], now: 100), .none)
    }
}

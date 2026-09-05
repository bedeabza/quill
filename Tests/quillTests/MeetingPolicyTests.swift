import XCTest
@testable import quill

final class MeetingPolicyTests: XCTestCase {
    let meeting = DetectedMeeting(id: "meet-1", app: "Brave", service: "Google Meet")

    func testDetectedMeetingStartsAutomaticallyOnce() {
        var policy = MeetingPolicy()
        XCTAssertEqual(policy.update([meeting.id: .present(meeting)], now: 0), .start(meeting))
        policy.recordingStarted(for: meeting, automatic: true)
        XCTAssertEqual(policy.update([meeting.id: .present(meeting)], now: 50), .none)
    }

    func testFailedStartDoesNotRetryEveryPoll() {
        var policy = MeetingPolicy()
        policy.startFailed(for: meeting)
        XCTAssertEqual(policy.update([meeting.id: .present(meeting)], now: 50), .none)
    }

    func testReenablingToggleAllowsTheSameMeetingToStartAgain() {
        var policy = MeetingPolicy()
        policy.recordingStarted(for: meeting, automatic: true)
        XCTAssertEqual(policy.setAutomationEnabled(false), .stop)
        policy.recordingStopped()
        _ = policy.setAutomationEnabled(true)
        XCTAssertEqual(policy.update([meeting.id: .present(meeting)], now: 10), .start(meeting))
    }

    func testToggleOffPreventsAutomaticStartAndStopsOnlyAutomaticRecordings() {
        var policy = MeetingPolicy()
        XCTAssertEqual(policy.setAutomationEnabled(false), .none)
        XCTAssertEqual(policy.update([meeting.id: .present(meeting)], now: 0), .none)
        _ = policy.setAutomationEnabled(true)
        policy.recordingStarted(for: meeting, automatic: true)
        XCTAssertEqual(policy.setAutomationEnabled(false), .stop)
        policy.recordingStopped()
        policy.recordingStarted(for: nil)
        XCTAssertEqual(policy.setAutomationEnabled(false), .none)
    }

    func testAnotherMeetingKeepsRecordingAfterFirstEnds() {
        var policy = MeetingPolicy()
        let other = DetectedMeeting(id: "zoom-1", app: "Zoom", service: "Zoom")
        policy.recordingStarted(for: meeting, automatic: true)
        XCTAssertEqual(policy.update([meeting.id: .ended, other.id: .present(other)], now: 100), .none)
        XCTAssertEqual(policy.recordingMeeting, other)
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

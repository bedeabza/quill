import XCTest
@testable import quill

final class PersistentSpeakerTrackingTests: XCTestCase {
    func testSameTabBreakoutRetainsRecordingBinding() {
        let meeting = DetectedMeeting(id: "original", app: "Brave", service: "Google Meet")
        let candidate = BrowserRoomBinding.Candidate(id: meeting.id, code: "old-room", sameTab: true, sameDocument: true)
        let id = BrowserRoomBinding.existingID([candidate], code: "breakout-room", hasTab: true)
        XCTAssertEqual(id, meeting.id)
        var policy = MeetingPolicy()
        policy.recordingStarted(for: meeting, automatic: true)
        XCTAssertEqual(policy.update([id!: .present(meeting)], now: 5), .none)
        XCTAssertEqual(policy.recordingMeeting, meeting)
        XCTAssertTrue(policy.recording)
    }

    func testReplacementDocumentUsesSameTabAndReturningToMainRoomWorks() {
        let candidate = BrowserRoomBinding.Candidate(id: "call", code: "breakout", sameTab: true, sameDocument: false)
        XCTAssertEqual(BrowserRoomBinding.existingID([candidate], code: "main", hasTab: true), "call")
    }

    func testAnotherTabNeverBorrowsSameRoomBinding() {
        let candidate = BrowserRoomBinding.Candidate(id: "other", code: "main", sameTab: false, sameDocument: false)
        XCTAssertNil(BrowserRoomBinding.existingID([candidate], code: "main", hasTab: true))
        XCTAssertNil(BrowserRoomBinding.existingID([candidate, candidate], code: "main", hasTab: false))
    }

    func testIdleDiscoverySeedsFreshMembershipButNeverPastSpeaking() {
        var tracking = SpeakerTrackingState()
        let meeting = DetectedMeeting(id: "call", app: "Brave", service: "Google Meet")
        tracking.update([meeting.id: .present(meeting)], at: 100)
        tracking.observe(SpeakerObservation(observed_at: 100, meeting_id: "call", names: ["Andrei"], source: "meeting_roster",
            participants: [.init(name: "Andrei", is_local: false)], participant_count: 2, roster_complete: true))
        let seed = tracking.seed(meetingID: "call", at: 102)
        XCTAssertEqual(seed?.participants?.first?.name, "Andrei")
        XCTAssertEqual(seed?.observed_at, 102)
        XCTAssertEqual(seed?.names, [])
        XCTAssertNil(tracking.seed(meetingID: "call", at: 106))
        XCTAssertNil(tracking.seed(meetingID: "call", at: 99))
    }

    func testSpeakerBindingSurvivesKeepRecordingAndRebindsAfterAnEnd() {
        var tracking = SpeakerTrackingState()
        let main = DetectedMeeting(id: "main", app: "Brave", service: "Google Meet")
        tracking.update([main.id: .present(main)], at: 0)
        XCTAssertEqual(tracking.recordingMeetingID(preferred: nil, previous: "main"), "main")
        let next = DetectedMeeting(id: "next", app: "Brave", service: "Google Meet")
        tracking.update([main.id: .ended, next.id: .present(next)], at: 1)
        XCTAssertEqual(tracking.recordingMeetingID(preferred: "main", previous: "main"), "next")
        tracking.update([main.id: .present(main), next.id: .present(next)], at: 2)
        XCTAssertNil(tracking.recordingMeetingID(preferred: nil, previous: nil))
        XCTAssertEqual(tracking.recordingMeetingID(preferred: nil, previous: "next"), "next")
    }

    func testRoomTransitionClosesOldRosterAndAcceptsNewParticipants() {
        var tracking = SpeakerTrackingState(), roster = ParticipantRoster(audio_started_at: 0)
        let old = SpeakerObservation(observed_at: 10, meeting_id: "call", names: [], source: "meeting_roster",
            participants: [.init(name: "Old person", is_local: false)], participant_count: 2, roster_complete: true)
        let transition = SpeakerObservation(observed_at: 15, meeting_id: "call", names: [], source: "meeting_roster",
            participants: [], roster_complete: false)
        tracking.observe(old); tracking.observe(transition)
        roster.observe(old, localName: "Local"); roster.observe(transition, localName: "Local")
        XCTAssertEqual(tracking.seed(meetingID: "call", at: 16)?.participants, [])
        XCTAssertNil(roster.soleRemoteIdentity(startMS: 16000, endMS: 17000))
        tracking.update(["call": .ended], at: 17)
        XCTAssertNil(tracking.seed(meetingID: "call", at: 17))
        XCTAssertTrue(tracking.meetingIDs.isEmpty)
    }
}

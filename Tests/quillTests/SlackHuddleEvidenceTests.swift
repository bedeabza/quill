import XCTest
@testable import quill

final class SlackHuddleEvidenceTests: XCTestCase {
    func testNativeSlackIdentityExcludesHelpersAndUnrelatedApps() {
        XCTAssertEqual(MeetingEvidence.nativeService(bundleID: "com.tinyspeck.slackmacgap"), "Slack")
        XCTAssertEqual(MeetingEvidence.nativeService(bundleID: "COM.TINYSPECK.SLACKMACGAP"), "Slack")
        XCTAssertNil(MeetingEvidence.nativeService(bundleID: "com.tinyspeck.slackmacgap.helper"))
        XCTAssertNil(MeetingEvidence.nativeService(bundleID: "com.example.slack"))
        XCTAssertEqual(MeetingEvidence.nativeService(bundleID: "com.microsoft.teams2"), "Microsoft Teams")
        XCTAssertEqual(MeetingEvidence.nativeService(bundleID: "us.zoom.xos"), "Zoom")
    }

    func testSlackClientAndHuddleURLsQualifyAcrossBrowserHosts() {
        for url in ["https://app.slack.com/client/T123/C123", "https://app.slack.com/huddle/T123/R123",
                    "https://example.slack.com/huddle/C123", "https://example.slack.com/messages/C123",
                    "https://example.slack.com/archives/C123", "https://APP.SLACK.COM/client/T123/C123?x=1"] {
            XCTAssertEqual(MeetingEvidence.service(url: url), "Slack", url)
        }
    }

    func testSlackHelpLinksLookalikeHostsAndLocalFilesDoNotQualify() {
        for url in ["https://slack.com/help/articles/4402059015315", "https://app.slack.com/",
                    "https://example.com/client/T123/C123?site=app.slack.com",
                    "https://app.slack.com.evil.test/client/T123/C123", "https://notslack.com/client/T123/C123",
                    "https://app.slack.com/client-lookalike/T123", "https://slack.com/huddle/C123",
                    "file://app.slack.com/client/T123/C123", "slack://app.slack.com/client/T123/C123"] {
            XCTAssertNil(MeetingEvidence.service(url: url), url)
        }
    }

    func testJoinedCompactAndExpandedHuddleControls() {
        for controls in [["Leave huddle"], ["Leave huddle (⌘⇧H)"], ["Leave the huddle"],
                         ["Leave", "Mute"], ["Leave", "Unmute microphone"],
                         ["Leave (⌘⇧H)", "Mute your microphone (⌘⇧M)"],
                         ["Leave call", "Unmute mic"], ["Hang up", "Turn off microphone"]] {
            XCTAssertTrue(SlackHuddleEvidence.hasJoinedControls(controls), "\(controls)")
            XCTAssertEqual(SlackHuddleEvidence.state(controls: controls, complete: true, visible: true), .joined)
        }
    }

    func testChatInvitationSettingsAndNavigationCannotStartRecording() {
        // Labels observed in the native Slack idle screen, plus ambiguous controls.
        for controls in [["Start huddle with Teammate", "Mute conversation", "Record audio clip"],
                         ["Join huddle", "Decline"], ["Leave", "Mute notifications"],
                         ["Leave", "Mute conversation"], ["Leave channel", "Mute microphone"],
                         ["Leave a comment", "Unmute microphone"], ["Leave"],
                         ["Preview video", "Mute microphone"], ["More Huddles options"],
                         ["How to leave huddle", "Share screen"], ["Leave huddle reminders"]] {
            XCTAssertFalse(SlackHuddleEvidence.hasJoinedControls(controls), "\(controls)")
        }
    }

    func testOnlyInteractiveRolesSupplyHuddleControls() {
        for role in ["AXButton", "AXCheckBox", "AXSwitch", "AXPopUpButton"] {
            XCTAssertTrue(SlackHuddleEvidence.isControl(role: role))
        }
        for role in ["AXStaticText", "AXTextArea", "AXHeading", "AXLink", "AXTab", "AXWindow"] {
            XCTAssertFalse(SlackHuddleEvidence.isControl(role: role))
        }
    }

    func testReturnedStartOrJoinControlsEndAnEstablishedHuddle() {
        for control in ["Start huddle", "Start huddle with Teammate", "Start huddle in general",
                        "Start a huddle", "Join huddle", "Join the huddle", "Rejoin huddle"] {
            XCTAssertEqual(SlackHuddleEvidence.state(controls: [control], complete: true, visible: true), .ended, control)
        }
    }

    func testAnotherConversationsStartButtonCannotEndActiveHuddle() {
        XCTAssertEqual(SlackHuddleEvidence.state(controls: ["Start huddle with Teammate", "Leave huddle"],
                                                complete: true, visible: true), .joined)
    }

    func testHiddenAndIncompleteReadsCannotEndOrResumeHuddle() {
        XCTAssertEqual(SlackHuddleEvidence.state(controls: ["Start huddle"], complete: false, visible: true), .unknown)
        XCTAssertEqual(SlackHuddleEvidence.state(controls: ["Start huddle"], complete: true, visible: false), .unknown)
        XCTAssertEqual(SlackHuddleEvidence.state(controls: ["Leave huddle"], complete: true, visible: false), .unknown)
        XCTAssertEqual(SlackHuddleEvidence.state(controls: [], complete: true, visible: true), .unknown)
        XCTAssertEqual(SlackHuddleEvidence.state(controls: ["Leave huddle"], complete: false, visible: true), .joined)
    }

    func testSlackLifecycleStopsWithChatOpenAndStartsOnRejoin() {
        for app in ["Slack", "Brave", "Google Chrome", "Firefox"] {
            let meeting = DetectedMeeting(id: "slack-1", app: app, service: "Slack")
            var policy = MeetingPolicy()
            var endState = MeetingEndState()
            func observation(_ controls: [String], visible: Bool = true) -> MeetingObservation {
                let state = SlackHuddleEvidence.state(controls: controls, complete: true, visible: visible)
                let ended = endState.isEnded(meeting.id, endScreen: state == .ended, inCall: state == .joined)
                return ended ? .ended : (state == .joined ? .present(meeting) : .unknown)
            }
            XCTAssertEqual(policy.update([meeting.id: observation(["Leave huddle"])], now: 0), .start(meeting))
            policy.recordingStarted(for: meeting, automatic: true)
            XCTAssertEqual(policy.update([meeting.id: observation(["Start huddle"])], now: 10), .countdown(30))
            // An ended Slack tab cannot restart recording from stale hidden controls.
            XCTAssertEqual(policy.update([meeting.id: observation(["Leave huddle"], visible: false)], now: 40), .stop)
            policy.recordingStopped()
            XCTAssertEqual(policy.update([meeting.id: observation(["Start huddle"])], now: 42), .none)
            XCTAssertEqual(policy.update([meeting.id: observation(["Leave", "Mute microphone"])], now: 45), .start(meeting))
        }
    }

    func testMissingControlsAndRejoiningCancelStopCountdown() {
        let meeting = DetectedMeeting(id: "slack-1", app: "Slack", service: "Slack")
        var policy = MeetingPolicy()
        policy.recordingStarted(for: meeting, automatic: true)
        XCTAssertEqual(policy.update([meeting.id: .unknown], now: 5), .unavailable)
        XCTAssertEqual(policy.update([meeting.id: .ended], now: 10), .countdown(30))
        XCTAssertEqual(policy.update([meeting.id: .present(meeting)], now: 25), .none)
        XCTAssertEqual(policy.update([meeting.id: .present(meeting)], now: 45), .none)
    }
}

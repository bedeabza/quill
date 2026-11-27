import XCTest
@testable import quill

final class TeamsMeetingEvidenceTests: XCTestCase {
    private let url = "https://teams.cloud.microsoft/v2/"
    private func control(_ label: String, role: String = "AXButton", description: String? = nil) -> TeamsMeetingEvidence.Control {
        .init(role: role, labels: [label] + (description.map { [$0] } ?? []))
    }
    private func state(_ controls: [TeamsMeetingEvidence.Control], texts: [String] = [], complete: Bool = true,
                       visible: Bool = true) -> TeamsMeetingEvidence.State {
        TeamsMeetingEvidence.state(url: url, controls: controls, texts: texts, complete: complete, visible: visible)
    }

    func testChromeSplitButtonsAndTogglesStartEnglishCall() {
        // Chrome may expose the visible label and accessibility description separately.
        // Joining them into "Leave Leave (...)" loses the short Leave control.
        XCTAssertEqual(state([control("Leave", role: "AXPopUpButton", description: "Leave (⌘⇧H)"),
                              control("Mic", role: "AXCheckBox", description: "Unmute mic (⌘⇧M)")]), .joined)
        XCTAssertEqual(state([control("Leave (Ctrl+Shift+H)", role: "AXPopUpButton"),
                              control("Turn on microphone", role: "AXSwitch")]), .joined)
        XCTAssertEqual(state([control("Hang up"), control("Unmute")]), .joined)
        XCTAssertEqual(state([control("Leave"), control("Mute"), control("Camera", role: "AXToggleButton")]), .joined)
    }

    func testRomanianControlsWithDiacriticsAndShortcutSuffixesStartCall() {
        for leave in ["Părăsiți", "Părăsiți întâlnirea", "Ieșiți din întâlnire", "Încheiați apelul"] {
            for mic in ["Microfon", "Dezactivați microfonul", "Activați microfonul"] {
                XCTAssertEqual(state([control(leave + " (Ctrl+Shift+H)", role: "AXPopUpButton"),
                                      control(mic, role: "AXCheckBox")]), .joined)
            }
        }
        XCTAssertEqual(state([control("  PARASITI  "), control("MICROFON")]), .joined)
        XCTAssertEqual(state([control("Părăsiți"), control("Activare sunet"), control("Cameră")]), .joined)
        XCTAssertEqual(state([control("Închideți"), control("Activați microfonul"), control("Afișare participanți")]), .joined)
        XCTAssertEqual(state([control("Închideți"), control("Microfon"), control("Afișare participanți"), control("Alăturați-vă la întâlnire")]), .ended)
    }

    func testPrejoinAndLobbyDoNotAuthorizeRecordingInEitherLanguage() {
        for join in ["Join now", "Rejoin", "Asociați-vă acum", "Alăturați-vă acum", "Participați acum", "Reasociere"] {
            XCTAssertEqual(state([control(join), control("Microphone"), control("Camera")]), .ended)
            // An incomplete prejoin page does not authorize either start or stop.
            XCTAssertEqual(state([control(join), control("Mic")], complete: false), .unknown)
        }
        for waiting in ["Someone in the meeting should let you in soon.", "Așteptați ca cineva să vă permită accesul."] {
            XCTAssertEqual(state([control("Leave"), control("Mic")], texts: [waiting]), .ended)
        }
        // A calendar invitation elsewhere in Teams does not override joined controls.
        XCTAssertEqual(state([control("Join now"), control("Leave"), control("Mic")]), .joined)
        // Being the first actual attendee is not the lobby.
        XCTAssertEqual(state([control("Leave"), control("Mic")], texts: ["Waiting for others to join"]), .joined)
    }

    func testChatNavigationTextAndAudioSettingsCannotStartRecording() {
        for leave in ["Leave chat", "Leave a comment", "Părăsiți conversația", "Închideți", "Leave (chat)"] {
            XCTAssertEqual(state([control(leave), control("Mic")]), .unknown)
        }
        for audio in ["Mute notifications", "Mute conversation", "Audio settings", "Dezactivați notificările"] {
            XCTAssertEqual(state([control("Leave"), control(audio)]), .unknown)
        }
        XCTAssertEqual(state([control("Leave"), control("Mute")]), .unknown)
        XCTAssertEqual(state([control("Leave", role: "AXStaticText"), control("Mic", role: "AXHeading")]), .unknown)
        XCTAssertEqual(state([], texts: ["Leave", "Mic"]), .unknown)
    }

    func testOnlyTrustedTeamsDocumentsSupplyEvidence() {
        let controls = [control("Leave"), control("Mic")]
        for host in ["teams.microsoft.com", "teams.live.com", "teams.cloud.microsoft"] {
            XCTAssertEqual(TeamsMeetingEvidence.state(url: "https://\(host)/v2/", controls: controls, complete: true, visible: true), .joined)
        }
        for fake in ["https://teams.cloud.microsoft.evil.test/v2/", "https://example.com/?teams.microsoft.com",
                     "file://teams.microsoft.com/meeting.html", "http://teams.microsoft.com/v2/", ""] {
            XCTAssertEqual(TeamsMeetingEvidence.state(url: fake, controls: controls, complete: true, visible: true), .unknown)
        }
        // The Teams document with no call controls cannot borrow them from a second document.
        XCTAssertEqual(state([]), .unknown)
        XCTAssertEqual(state(controls, visible: false), .unknown)
    }

    func testMissingControlsAndIncompleteEndScreensRemainUnknown() {
        XCTAssertEqual(state([], complete: true), .unknown)
        XCTAssertEqual(state([], texts: ["You left the meeting"], complete: false), .unknown)
        XCTAssertEqual(state([], texts: ["Ați părăsit întâlnirea"], visible: false), .unknown)
        for message in ["You left the meeting.", "The meeting has ended", "Ați părăsit întâlnirea.", "Întâlnirea s-a încheiat."] {
            XCTAssertEqual(state([], texts: [message]), .ended)
        }
        XCTAssertEqual(state([], texts: ["When the meeting has ended, close this tab"]), .unknown)
        XCTAssertEqual(state([control("Leave"), control("Mic")], texts: ["You left the meeting"]), .joined)
    }

    func testJoinedTeamsCallDrivesAutomaticRecordingOnceAndRejoinRestarts() {
        let meeting = DetectedMeeting(id: "teams-chrome", app: "Google Chrome", service: "Microsoft Teams")
        var policy = MeetingPolicy(), end = MeetingEndState()
        func observation(_ state: TeamsMeetingEvidence.State) -> MeetingObservation {
            if end.isEnded(meeting.id, endScreen: state == .ended, inCall: state == .joined) { return .ended }
            return state == .joined ? .present(meeting) : .unknown
        }
        XCTAssertEqual(policy.update([meeting.id: observation(state([control("Join now"), control("Mic")]))], now: 0), .none)
        let joined = state([control("Leave", role: "AXPopUpButton"), control("Mic", role: "AXCheckBox")])
        XCTAssertEqual(policy.update([meeting.id: observation(joined)], now: 2), .start(meeting))
        policy.recordingStarted(for: meeting, automatic: true)
        XCTAssertEqual(policy.update([meeting.id: observation(joined)], now: 4), .none)
        let ended = state([], texts: ["Ați părăsit întâlnirea."])
        XCTAssertEqual(policy.update([meeting.id: observation(ended)], now: 10), .countdown(30))
        // Remember the explicit end even if the ended tab later becomes hidden.
        XCTAssertEqual(policy.update([meeting.id: observation(.unknown)], now: 40), .stop)
        policy.recordingStopped()
        XCTAssertEqual(policy.update([meeting.id: observation(joined)], now: 42), .start(meeting))
    }

    func testIncompleteReadsDoNotStopAnEstablishedRecording() {
        let meeting = DetectedMeeting(id: "teams-chrome", app: "Google Chrome", service: "Microsoft Teams")
        var policy = MeetingPolicy()
        policy.recordingStarted(for: meeting, automatic: true)
        XCTAssertEqual(state([], complete: false), .unknown)
        XCTAssertEqual(policy.update([meeting.id: .unknown], now: 100), .unavailable)
        XCTAssertTrue(policy.recording)
        XCTAssertEqual(policy.update([meeting.id: .present(meeting)], now: 102), .none)
    }
}

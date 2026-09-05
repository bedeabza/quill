import XCTest
@testable import quill

final class MeetingBannerTests: XCTestCase {
    @MainActor
    func testRecordingEventsRequestNativeNotifications() async {
        var messages: [(String, String)] = []
        let assistant = MeetingAssistant(recordingNotification: { messages.append(($0, $1)) })
        assistant.recordingStarted()
        assistant.recordingStopped()
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages.map { $0.0 }, ["Quill: Recording started", "Quill: Recording stopped"])
        XCTAssertEqual(messages.map { $0.1 }, [
            "Recording microphone and system audio.",
            "Your recording is being prepared for transcription.",
        ])
        assistant.shutdown()
        XCTAssertEqual(messages.count, 2)
    }
}

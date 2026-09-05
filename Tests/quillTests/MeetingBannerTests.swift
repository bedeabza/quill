import AppKit
import XCTest
@testable import quill

final class MeetingBannerTests: XCTestCase {
    @MainActor
    func testRecordingEventsShowBannersWithoutConfirmationControls() async {
        NSApplication.shared.setActivationPolicy(.accessory)
        let assistant = MeetingAssistant()
        defer { assistant.shutdown() }

        // Drive only the UI event callbacks; this does not capture audio.
        assistant.recordingStarted()
        var banner = NSApp.windows.first { $0.title == "Quill" && $0.isVisible }
        XCTAssertNotNil(banner)
        XCTAssertTrue(banner?.contentView?.subviews.compactMap { ($0 as? NSTextField)?.stringValue }
            .contains("Quill: Recording started") == true)
        XCTAssertFalse(banner?.contentView?.subviews.contains { $0 is NSButton } ?? true)

        assistant.recordingStopped()
        banner = NSApp.windows.first { $0.title == "Quill" && $0.isVisible }
        XCTAssertTrue(banner?.contentView?.subviews.compactMap { ($0 as? NSTextField)?.stringValue }
            .contains("Quill: Recording stopped") == true)
        XCTAssertFalse(banner?.contentView?.subviews.contains { $0 is NSButton } ?? true)
        assistant.shutdown()
        XCTAssertFalse(banner?.isVisible ?? true)
    }
}

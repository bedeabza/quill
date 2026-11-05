import AppKit
import XCTest
@testable import quill

@MainActor
final class MenuBarControllerTests: XCTestCase {
    private func visibleTitles(_ menu: NSMenu) -> [String] {
        menu.items.filter { !$0.isHidden && !$0.isSeparatorItem }.map(\.title)
    }

    /// Changes reach the menu on the next main-actor turn.
    private func settle() async { for _ in 0..<5 { await Task.yield() } }

    func testMenuFollowsAppStateAndKeepsOnlyRecordingAndDetection() async throws {
        let state = AppState()
        let controller = MenuBarController(appState: state)
        defer { NSStatusBar.system.removeStatusItem(controller.statusItem) }
        let menu = try XCTUnwrap(controller.statusItem.menu)

        XCTAssertEqual(visibleTitles(menu), ["Idle", "Start Recording", "Meeting detection on",
                                             "Automatic Meeting Recording", "Open Quill…", "Quit Quill"])
        XCTAssertNil(controller.statusItem.button?.contentTintColor)

        state.recording = true
        state.elapsed = "12:34"
        state.transcriptionStatus = "Transcribing 2026.11.02-1000 · 1 queued"
        state.detectionText = "Meeting detection needs Accessibility permission"
        state.detectionEnabled = true
        await settle()
        XCTAssertEqual(visibleTitles(menu), ["Recording · 12:34", "Transcribing 2026.11.02-1000 · 1 queued",
                                             "Stop Recording", "Keep Recording After Meeting Ends",
                                             "Meeting detection needs Accessibility permission", "Automatic Meeting Recording",
                                             "Allow meeting detection…", "Open Quill…", "Quit Quill"])
        XCTAssertEqual(menu.items.first { $0.title == "Automatic Meeting Recording" }?.state, .on)
        XCTAssertEqual(controller.statusItem.button?.contentTintColor, .systemRed)

        var opened: [QuillSection] = []
        controller.onOpen = { opened.append($0) }
        for title in ["Allow meeting detection…", "Open Quill…"] {
            let item = try XCTUnwrap(menu.items.first { $0.title == title })
            menu.performActionForItem(at: menu.index(of: item))
        }
        XCTAssertEqual(opened, [.permissions, .recordings])
    }
}

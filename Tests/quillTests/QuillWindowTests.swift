import AppKit
import XCTest
@testable import quill

@MainActor
final class QuillWindowTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Lets SwiftUI apply the selection and redraw.
    private func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }

    private func outline(in view: NSView) -> NSOutlineView? {
        if let outline = view as? NSOutlineView { return outline }
        for child in view.subviews { if let found = outline(in: child) { return found } }
        return nil
    }


    func testClickingEverySidebarRowShowsItsSection() throws {
        let appState = AppState()
        let permissions = PermissionsModel(root: root)
        let controller = QuillWindowController(appState: appState,
                                               recordings: RecordingsModel(root: root, transcription: TranscriptionCoordinator()),
                                               permissions: permissions,
                                               settings: SettingsModel(appState: appState))
        controller.show(section: .recordings)
        defer { controller.close() }
        settle()
        let window = try XCTUnwrap(controller.window)
        let outline = try XCTUnwrap(outline(in: try XCTUnwrap(window.contentView)))

        // Sidebar rows, top to bottom; row 1 is the "Settings" header.
        let rows: [QuillSection: Int] = [.recordings: 0, .transcription: 2, .meetings: 3, .permissions: 4, .general: 5]
        XCTAssertEqual(outline.numberOfRows, 6)
        for section in [QuillSection.transcription, .meetings, .recordings, .permissions, .general, .recordings,
                        .meetings, .permissions, .transcription, .general, .permissions, .recordings] {
            // What a click does to the sidebar's table; SwiftUI maps the row back to its tag.
            outline.selectRowIndexes(IndexSet(integer: rows[section]!), byExtendingSelection: false)
            settle()
            XCTAssertEqual(controller.navigation.section, section, "clicking \(section.title)")
            XCTAssertEqual(window.title, section.title, "detail after clicking \(section.title)")
        }

        // The menu's "Allow meeting detection…" and the Meetings section's Open Permissions
        // switch the section in code; the sidebar follows.
        for (section, row) in [(QuillSection.recordings, 0), (.permissions, 4), (.meetings, 3)] {
            controller.show(section: section)
            settle()
            XCTAssertEqual(window.title, section.title)
            XCTAssertEqual(outline.selectedRow, row, "sidebar after showing \(section.title)")
        }
        controller.navigation.section = .permissions
        settle()
        XCTAssertEqual(window.title, "Permissions")
        XCTAssertEqual(outline.selectedRow, 4)
    }
}

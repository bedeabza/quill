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

    func testLongTranscriptCannotPushSidebarRowsOutsideTheWindow() async throws {
        let directory = root.appendingPathComponent("2026.11.09-1000")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try Data(#"{"started":"2026-11-09T08:00:00Z","files":{}}"#.utf8)
            .write(to: directory.appendingPathComponent("meta.json"))
        try Transcript(engine: "elevenlabs", model: "scribe_v2", created_at: "fixture", segments: (0..<100).map { index in
            .init(speaker: "meeting_\(index % 3 + 1)", start_ms: index * 40000, end_ms: index * 40000 + 30000,
                  text: "Customer onboarding needs a simpler account setup before the autumn product launch. The team reviews feedback and discusses the next rollout milestones.", source: "meeting")
        }, variant: "elevenlabs_original").write(to: directory)
        _ = await RecordingTitles.generate(in: directory, mode: .claude) { _, _, _, _ in
            ("claude", Data(#"{"title":"Customer onboarding for the autumn launch: simplifying account setup, resolving feedback and agreeing the rollout priorities"}"#.utf8))
        }
        let appState = AppState()
        let recordings = RecordingsModel(root: root, transcription: TranscriptionCoordinator(),
            titles: RecordingTitleCoordinator(mode: { .off }, generate: { _, _, _ in }))
        recordings.refresh()
        for _ in 0..<100 {
            if recordings.transcript != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(recordings.transcript)
        let controller = QuillWindowController(appState: appState, recordings: recordings,
            permissions: PermissionsModel(root: root),
            settings: SettingsModel(appState: appState, keyStore: ElevenLabsKeyStore(url: root.appendingPathComponent("fixture-key"))))
        let window = try XCTUnwrap(controller.window)
        defer { controller.close() }
        window.orderBack(nil)
        func sidebar(_ view: NSView) -> NSOutlineView? {
            if let table = view as? NSOutlineView, table.numberOfRows == 6 { return table }
            for child in view.subviews { if let found = sidebar(child) { return found } }
            return nil
        }
        func scrollViews(_ view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
        }
        for size in [NSSize(width: 1100, height: 720), NSSize(width: 900, height: 600)] {
            window.setContentSize(size)
            settle()
            let content = try XCTUnwrap(window.contentView)
            let table = try XCTUnwrap(sidebar(content))
            XCTAssertTrue(window.frame.height < size.height + 100, "a transcript must not become the window's minimum height")
            for row in [0, 2, 3, 4, 5] {
                let rect = content.convert(table.rect(ofRow: row), from: table)
                XCTAssertTrue(content.bounds.intersects(rect), "sidebar row \(row) is clipped at \(size)")
            }
            let transcript = scrollViews(content).first { ($0.documentView?.frame.height ?? 0) > 2000 }
            XCTAssertNotNil(transcript)
            XCTAssertTrue((transcript?.contentSize.height ?? 0) >= 100, "the transcript needs a bounded, usable viewport")
            for section in QuillSection.allCases {
                controller.navigation.section = section
                settle()
                let rect = content.convert(table.rect(ofRow: 0), from: table)
                XCTAssertTrue(content.bounds.intersects(rect), "sidebar remains visible in \(section.title)")
            }
            controller.navigation.section = .recordings
            settle()
        }
    }
}

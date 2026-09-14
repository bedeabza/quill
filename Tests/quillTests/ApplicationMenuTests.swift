import AppKit
import XCTest
@testable import quill

@MainActor
private final class EditingCommandTarget: NSObject {
    var pastes = 0
    var selections = 0
    @objc func paste(_ sender: Any?) { pastes += 1 }
    @objc func selectAll(_ sender: Any?) { selections += 1 }
}

final class ApplicationMenuTests: XCTestCase {
    @MainActor
    func testNativeEditingShortcutsDispatchThroughApplicationMenu() throws {
        let app = NSApplication.shared
        let previousMenu = app.mainMenu
        let menu = ApplicationMenu.make()
        app.mainMenu = menu
        defer { app.mainMenu = previousMenu }
        let edit = try XCTUnwrap(menu.items.first(where: { $0.title == "Edit" })?.submenu)
        let target = EditingCommandTarget()
        for item in edit.items where !item.isSeparatorItem {
            XCTAssertNil(item.target, "Production editing commands must use the focused responder")
            item.target = target
        }
        func press(_ character: String, modifiers: NSEvent.ModifierFlags = .command) throws -> Bool {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: 0, windowNumber: 0, context: nil, characters: character,
                charactersIgnoringModifiers: character, isARepeat: false, keyCode: character == "v" ? 9 : 0))
            return menu.performKeyEquivalent(with: event)
        }
        XCTAssertTrue(try press("v"))
        XCTAssertEqual(target.pastes, 1)
        XCTAssertTrue(try press("a"))
        XCTAssertEqual(target.selections, 1)
        XCTAssertFalse(try press("v", modifiers: []))
        XCTAssertEqual(target.pastes, 1, "Ordinary typing must not read the clipboard")
    }
}

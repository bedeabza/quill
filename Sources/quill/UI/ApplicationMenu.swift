import AppKit

/// Programmatic accessory apps have no nib-provided Edit menu. Native text
/// fields rely on its responder-chain actions for Command-V and Command-A.
@MainActor
enum ApplicationMenu {
    static func make() -> NSMenu {
        let menu = NSMenu()
        let application = NSMenuItem(title: "Quill", action: nil, keyEquivalent: "")
        let applicationMenu = NSMenu(title: "Quill")
        applicationMenu.addItem(withTitle: "Quit Quill", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        application.submenu = applicationMenu
        menu.addItem(application)

        let edit = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        // Nil targets let AppKit route editing to the focused text field.
        edit.submenu = editMenu
        menu.addItem(edit)
        return menu
    }
}

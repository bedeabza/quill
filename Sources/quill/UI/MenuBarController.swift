import AppKit
import Observation
import SwiftUI

/// Status bar item in the top-right of the menu bar: the feather (red while
/// recording) and a short menu for recording and meeting detection. Settings,
/// recordings and permissions live in the Quill window. Everything shown
/// follows `AppState`.
@MainActor
final class MenuBarController: NSObject {
    private let appState: AppState
    let statusItem: NSStatusItem
    private let stateLine = StatusLineItem()
    private let transcriptionLine = StatusLineItem()
    private let toggleItem = NSMenuItem(title: "Start Recording", action: #selector(toggleClicked), keyEquivalent: "r")
    private let keepItem = NSMenuItem(title: "Keep Recording After Meeting Ends", action: #selector(keepClicked), keyEquivalent: "")
    private let detectionLine = StatusLineItem()
    private let detectionToggle = NSMenuItem(title: "Automatic Meeting Recording", action: #selector(detectionClicked), keyEquivalent: "")
    private let permissionItem = NSMenuItem(title: "Allow meeting detection…", action: #selector(permissionClicked), keyEquivalent: "")

    /// Opens the Quill window at a section.
    var onOpen: (QuillSection) -> Void = { _ in }

    init(appState: AppState) {
        self.appState = appState
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        let menu = NSMenu()
        menu.autoenablesItems = false
        let open = NSMenuItem(title: "Open Quill…", action: #selector(openClicked), keyEquivalent: "o")
        let quit = NSMenuItem(title: "Quit Quill", action: #selector(quitClicked), keyEquivalent: "q")
        for item in [stateLine.item, transcriptionLine.item, .separator(),
                     toggleItem, keepItem, .separator(),
                     detectionLine.item, detectionToggle, permissionItem, .separator(),
                     open, .separator(), quit] {
            if item.action != nil { item.target = self }
            menu.addItem(item)
        }
        statusItem.menu = menu

        if let button = statusItem.button {
            button.image = Self.featherImage()
            button.imagePosition = .imageLeft
        }
        observe()
    }

    /// Renders now and again whenever a value it read changes.
    private func observe() {
        withObservationTracking { render() } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
    }

    private func render() {
        let state = appState
        stateLine.show(state.recording ? "Recording · \(state.elapsed ?? "0:00")" : "Idle",
                       dot: state.recording ? .red : nil, primary: state.recording)
        transcriptionLine.show(state.transcriptionStatus ?? "")
        transcriptionLine.item.isHidden = state.transcriptionStatus == nil
        toggleItem.title = state.recording ? "Stop Recording" : "Start Recording"
        keepItem.isHidden = !state.recording
        detectionLine.show(state.detectionText)
        detectionToggle.state = state.detectionEnabled ? .on : .off
        permissionItem.isHidden = !state.needsMeetingPermission
        permissionItem.title = state.meetingPermissionTitle
        statusItem.button?.contentTintColor = state.recording ? .systemRed : nil
    }

    @objc private func toggleClicked() { appState.toggleRecording() }
    @objc private func keepClicked() { appState.keepRecording() }
    @objc private func detectionClicked() { appState.toggleDetection() }
    @objc private func permissionClicked() { onOpen(.permissions) }
    @objc private func openClicked() { onOpen(.recordings) }
    @objc private func quitClicked() { appState.quit() }

    // Inlined Lucide feather SVG. Keeping it in source means the executable
    // has no separate resource bundle to install alongside it — true
    // single-binary.
    private static let featherSVG = """
    <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" \
    viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" \
    stroke-linecap="round" stroke-linejoin="round">\
    <path d="M12.67 19a2 2 0 0 0 1.416-.588l6.154-6.172a6 6 0 0 0-8.49-8.49L5.586 9.914A2 2 0 0 0 5 11.328V18a1 1 0 0 0 1 1z"/>\
    <path d="M16 8 2 22"/>\
    <path d="M17.5 15H9"/>\
    </svg>
    """

    private static func featherImage() -> NSImage? {
        guard let image = NSImage(data: Data(featherSVG.utf8)) else { return nil }
        // Menu-bar status icons are nominally 18pt tall; size the SVG to match.
        image.size = NSSize(width: 16, height: 16)
        image.isTemplate = true
        return image
    }
}

/// A menu line that reads as information rather than a greyed-out command.
@MainActor
final class StatusLineItem {
    let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let host = NSHostingView(rootView: StatusLine(text: "", dot: nil, primary: false))

    init() {
        item.isEnabled = false
        item.view = host
    }

    func show(_ text: String, dot: Color? = nil, primary: Bool = false) {
        let line = StatusLine(text: text, dot: dot, primary: primary)
        guard host.rootView != line else { return }
        item.title = text // for accessibility and menu search
        host.rootView = line
        host.frame.size = host.fittingSize
    }
}

struct StatusLine: View, Equatable {
    let text: String
    let dot: Color?
    let primary: Bool

    var body: some View {
        HStack(spacing: 6) {
            if let dot {
                Circle().fill(dot).frame(width: 8, height: 8)
            }
            Text(text)
                .monospacedDigit()
                .fontWeight(primary ? .medium : .regular)
                .foregroundStyle(primary ? .primary : .secondary)
        }
        .font(.system(size: NSFont.menuFont(ofSize: 0).pointSize))
        // Text lines up with the item titles; the dot sits in the checkmark column.
        .padding(.leading, dot == nil ? 30 : 16)
        .padding(.trailing, 16)
        .frame(height: 24, alignment: .leading)
    }
}

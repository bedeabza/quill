import AppKit
import Observation
import SwiftUI

/// The sections of the Quill window, in sidebar order.
enum QuillSection: String, CaseIterable, Hashable {
    case recordings, transcription, meetings, permissions, general

    var title: String {
        switch self {
        case .recordings: "Recordings"
        case .transcription: "Transcription"
        case .meetings: "Meetings"
        case .permissions: "Permissions"
        case .general: "General"
        }
    }

    var symbol: String {
        switch self {
        case .recordings: "waveform"
        case .transcription: "text.quote"
        case .meetings: "video"
        case .permissions: "hand.raised"
        case .general: "gearshape"
        }
    }
}

/// The visible section, shared by the sidebar and the window controller.
@Observable @MainActor
final class QuillNavigation {
    var section: QuillSection = .recordings {
        didSet { if section != oldValue { onChange() } }
    }
    @ObservationIgnored var onChange: () -> Void = {}
}

/// Quill's one window: recordings, settings and permissions. A single instance
/// is reused; closing it keeps Quill running in the menu bar. Model polling
/// runs only for the visible section while the window is open.
@MainActor
final class QuillWindowController: NSWindowController, NSWindowDelegate {
    let recordings: RecordingsModel
    let permissions: PermissionsModel
    let settings: SettingsModel
    let navigation = QuillNavigation()
    private var isOpen = false

    init(appState: AppState, recordings: RecordingsModel, permissions: PermissionsModel, settings: SettingsModel) {
        self.recordings = recordings
        self.permissions = permissions
        self.settings = settings
        let size = NSSize(width: 1100, height: 720)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Quill"
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .unified
        let root = QuillWindow(navigation: navigation, appState: appState, recordings: recordings,
                               permissions: permissions, settings: settings)
        let hosting = NSHostingController(rootView: root)
        // SwiftUI sets the minimum size; the frame itself is ours and autosaved.
        hosting.sizingOptions = [.minSize]
        window.contentViewController = hosting
        window.setContentSize(size)
        super.init(window: window)
        window.delegate = self
        if !window.setFrameUsingName(Self.autosaveName) { window.center() }
        window.setFrameAutosaveName(Self.autosaveName)
        navigation.onChange = { [weak self] in self?.updatePolling() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private static let autosaveName = "QuillWindow"

    /// Brings the window forward at `section` and activates Quill, which stays
    /// an accessory app without a Dock icon.
    func show(section: QuillSection) {
        let opening = !isOpen
        isOpen = true
        navigation.section = section
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // One check on opening keeps the sidebar badge honest; polling runs only on Permissions.
        if opening && section != .permissions { permissions.refresh() }
        updatePolling()
    }

    /// Picks up finished transcriptions while the window is open.
    func refreshRecordings() {
        if isOpen { recordings.refresh() }
    }

    func windowWillClose(_ notification: Notification) {
        isOpen = false
        updatePolling()
    }

    private func updatePolling() {
        let section = isOpen ? navigation.section : nil
        if section == .recordings { recordings.start() } else { recordings.stop() }
        if section == .permissions { permissions.start() } else { permissions.stop() }
        if section == .transcription || section == .meetings { settings.reload() }
    }
}

/// Root view: the sidebar and the selected section.
struct QuillWindow: View {
    @Bindable var navigation: QuillNavigation
    let appState: AppState
    let recordings: RecordingsModel
    let permissions: PermissionsModel
    let settings: SettingsModel

    var body: some View {
        NavigationSplitView {
            List(selection: selection) {
                row(.recordings)
                Section("Settings") {
                    row(.transcription)
                    row(.meetings)
                    row(.permissions, badge: permissions.attentionCount)
                    row(.general)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
        } detail: {
            switch navigation.section {
            case .recordings: RecordingsView(model: recordings)
            case .transcription: TranscriptionSettingsView(model: settings)
            case .meetings: MeetingsSettingsView(model: settings, appState: appState, navigation: navigation)
            case .permissions: PermissionsView(model: permissions, engine: settings.engine)
            case .general: GeneralSettingsView(root: recordings.defaultRoot, appState: appState)
            }
        }
        .frame(minWidth: 900, minHeight: 600)
    }

    /// Clicking empty sidebar space must not clear the section.
    private var selection: Binding<QuillSection?> {
        Binding(get: { navigation.section }, set: { if let section = $0 { navigation.section = section } })
    }

    /// The tag must stay the row's outermost modifier: a `.badge` applied after it
    /// hides the tag from the List, so clicking that row selects nothing.
    private func row(_ section: QuillSection, badge: Int = 0) -> some View {
        Label(section.title, systemImage: section.symbol)
            .badge(badge)
            .tag(section)
    }
}

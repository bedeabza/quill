import AppKit

/// Status bar item in the top-right of the menu bar. Shows recording state at
/// a glance and provides the only persistent control surface for the daemon
/// (since we run as `.accessory` — no dock icon, no main window).
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let stateLabel: NSMenuItem
    private let transcriptionLabel: NSMenuItem
    private let toggleItem: NSMenuItem
    private let detectionLabel = NSMenuItem(title: "Meeting detection on", action: nil, keyEquivalent: "")
    private let detectionToggle = NSMenuItem(title: "Automatic meeting recording", action: #selector(detectionClicked), keyEquivalent: "")
    private let permissionItem = NSMenuItem(title: "Allow meeting detection...", action: #selector(permissionClicked), keyEquivalent: "")
    private var postProcessingItems: [NSMenuItem] = []
    private var engineItems: [NSMenuItem] = []
    private let voiceMemoryItem = NSMenuItem(title: "Remember speaker voices", action: #selector(voiceMemoryClicked), keyEquivalent: "")
    private let apiKeyItem = NSMenuItem(title: "ElevenLabs API key...", action: #selector(apiKeyClicked), keyEquivalent: "")
    private let removeKeyItem = NSMenuItem(title: "Remove ElevenLabs API key", action: #selector(removeKeyClicked), keyEquivalent: "")
    private let keepItem = NSMenuItem(title: "Keep recording after meeting ends", action: #selector(keepClicked), keyEquivalent: "")

    var onToggle: (() -> Void)?
    var onOpenFolder: (() -> Void)?
    var onQuit: (() -> Void)?
    var onDetectionToggle: (() -> Void)?
    var onPermission: (() -> Void)?
    var onKeepRecording: (() -> Void)?

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let menu = NSMenu()
        menu.autoenablesItems = false

        stateLabel = NSMenuItem(title: "idle", action: nil, keyEquivalent: "")
        stateLabel.isEnabled = false
        menu.addItem(stateLabel)

        transcriptionLabel = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        transcriptionLabel.isEnabled = false
        transcriptionLabel.isHidden = true
        menu.addItem(transcriptionLabel)

        menu.addItem(.separator())

        toggleItem = NSMenuItem(
            title: "Start recording",
            action: #selector(toggleClicked),
            keyEquivalent: "r"
        )
        super.init()
        menu.delegate = self
        menu.addItem(toggleItem)
        detectionLabel.isEnabled = false
        menu.addItem(keepItem)
        menu.addItem(.separator())
        menu.addItem(detectionLabel)
        menu.addItem(detectionToggle)
        menu.addItem(permissionItem)
        voiceMemoryItem.target = self
        voiceMemoryItem.toolTip = "Learn verified speaker voices locally and recognize them in later recordings."
        menu.addItem(voiceMemoryItem)

        let engine = NSMenuItem(title: "Transcription engine", action: nil, keyEquivalent: "")
        let engineMenu = NSMenu()
        engineMenu.autoenablesItems = false
        for (index, kind) in TranscriptionEngineKind.allCases.enumerated() {
            let item = NSMenuItem(title: kind.title, action: #selector(engineClicked(_:)), keyEquivalent: "")
            item.tag = index
            item.target = self
            item.toolTip = kind == .elevenLabs ? "Uploads audio to ElevenLabs. Applies when the next transcription starts." : "Transcribes on this Mac. Applies when the next transcription starts."
            engineItems.append(item)
            engineMenu.addItem(item)
        }
        engine.submenu = engineMenu
        menu.addItem(engine)
        apiKeyItem.target = self
        removeKeyItem.target = self
        menu.addItem(apiKeyItem)
        menu.addItem(removeKeyItem)

        let cleanup = NSMenuItem(title: "Transcript cleanup (cloud)", action: nil, keyEquivalent: "")
        let cleanupMenu = NSMenu()
        cleanupMenu.autoenablesItems = false
        for (index, title) in ["Off", "Automatic", "Codex (ChatGPT account)", "Claude Code"].enumerated() {
            let item = NSMenuItem(title: title, action: #selector(postProcessingClicked(_:)), keyEquivalent: "")
            item.tag = index
            item.target = self
            postProcessingItems.append(item)
            cleanupMenu.addItem(item)
        }
        cleanup.submenu = cleanupMenu
        menu.addItem(cleanup)

        let openFolder = NSMenuItem(
            title: "Open recordings folder",
            action: #selector(openFolderClicked),
            keyEquivalent: "o"
        )
        menu.addItem(openFolder)

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit quill",
            action: #selector(quitClicked),
            keyEquivalent: "q"
        )
        menu.addItem(quit)

        for item in [toggleItem, openFolder, quit, detectionToggle, permissionItem, keepItem] {
            item.target = self
        }

        statusItem.menu = menu

        if let button = statusItem.button {
            let image = Self.featherImage()
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageLeft
        }
    }

    /// Reflect recording state in the icon tint and menu item titles. The
    /// menu bar shows only the feather (red while recording); the elapsed
    /// counter lives in the menu's state label. Call once a second while
    /// recording.
    func update(recording: Bool, elapsed: String?) {
        stateLabel.title = recording ? "● recording · \(elapsed ?? "0:00")" : "idle"
        toggleItem.title = recording ? "Stop recording" : "Start recording"
        keepItem.isHidden = !recording
        statusItem.button?.contentTintColor = recording ? .systemRed : nil
    }

    /// Show transcription progress/failure as a second status line in the
    /// menu; nil hides it. Independent of recording state — a new recording
    /// can run while the last one transcribes.
    func updateTranscription(_ text: String?) {
        transcriptionLabel.title = text ?? ""
        transcriptionLabel.isHidden = text == nil
    }

    func updateDetection(_ text: String, enabled: Bool) {
        detectionLabel.title = text
        detectionToggle.state = enabled ? .on : .off
        permissionItem.isHidden = !text.contains("permission")
        permissionItem.title = text.contains("Screen Recording") ? "Allow Zoom speaker names..." : "Allow meeting detection..."
    }

    @objc private func voiceMemoryClicked() {
        do { try Config.setVoiceMemoryEnabled(!Config.voiceMemoryEnabled()) }
        catch { notifyUser(title: "Quill speaker memory", body: "Could not save the speaker memory setting: \(error)") }
    }

    func menuWillOpen(_ menu: NSMenu) {
        voiceMemoryItem.state = Config.voiceMemoryEnabled() ? .on : .off
        let hasKey = ElevenLabsKeychain.shared.containsKey()
        apiKeyItem.title = hasKey ? "Change ElevenLabs API key..." : "Set ElevenLabs API key..."
        removeKeyItem.isHidden = !hasKey
        for item in engineItems {
            item.state = TranscriptionEngineKind.allCases[item.tag].rawValue == Config.transcriptionEngine() ? .on : .off
        }
        let selected = Config.postProcessing().mode
        for item in postProcessingItems {
            item.state = PostProcessingMode.allCases[item.tag] == selected ? .on : .off
        }
    }

    @objc private func engineClicked(_ sender: NSMenuItem) {
        let kind = TranscriptionEngineKind.allCases[sender.tag]
        if kind == .elevenLabs && !ElevenLabsKeychain.shared.containsKey(), !enterAPIKey() { return }
        guard Config.setTranscriptionEngine(kind) else {
            notifyUser(title: "Quill settings", body: "Could not save the transcription engine setting.")
            return
        }
        for item in engineItems { item.state = item === sender ? .on : .off }
        notifyUser(title: "Quill transcription", body: "\(kind.title) will be used for the next transcription.")
    }

    @objc private func apiKeyClicked() { _ = enterAPIKey() }

    @discardableResult private func enterAPIKey() -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "ElevenLabs API key"
        alert.informativeText = "Your key is stored encrypted in macOS Keychain. Selecting ElevenLabs sends recording audio to Scribe v2 for transcription."
        alert.addButton(withTitle: "Save key")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 26))
        field.usesSingleLineMode = true
        field.placeholderString = "Paste your ElevenLabs API key"
        field.setAccessibilityLabel("ElevenLabs API key")
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        defer { field.stringValue = "" }
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        do {
            try ElevenLabsKeychain.shared.save(field.stringValue)
            notifyUser(title: "Quill settings", body: "ElevenLabs API key saved in macOS Keychain.")
            return true
        } catch {
            let failure = NSAlert()
            failure.messageText = "Could not save the API key"
            failure.informativeText = String(describing: error)
            failure.runModal()
            return false
        }
    }

    @objc private func removeKeyClicked() {
        do {
            try ElevenLabsKeychain.shared.remove()
            notifyUser(title: "Quill settings", body: "ElevenLabs API key removed. Select Parakeet or save another key to resume transcription.")
        } catch {
            notifyUser(title: "Quill settings", body: String(describing: error))
        }
    }

    @objc private func postProcessingClicked(_ sender: NSMenuItem) {
        let mode = PostProcessingMode.allCases[sender.tag]
        guard Config.setPostProcessingMode(mode) else {
            notifyUser(title: "Quill settings", body: "Could not save the transcript cleanup setting.")
            return
        }
        for item in postProcessingItems { item.state = item === sender ? .on : .off }
    }

    @objc private func detectionClicked() { onDetectionToggle?() }
    @objc private func permissionClicked() { onPermission?() }
    @objc private func keepClicked() { onKeepRecording?() }

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
        guard let data = featherSVG.data(using: .utf8),
              let image = NSImage(data: data)
        else { return nil }
        // Menu-bar status icons are nominally 18pt tall; size the SVG to match.
        image.size = NSSize(width: 16, height: 16)
        return image
    }

    @objc private func toggleClicked() { onToggle?() }
    @objc private func openFolderClicked() { onOpenFolder?() }
    @objc private func quitClicked() { onQuit?() }
}

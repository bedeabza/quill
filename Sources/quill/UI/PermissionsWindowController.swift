import AppKit
@preconcurrency import ApplicationServices
import AVFoundation

@MainActor
private final class PermissionsDocumentView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
final class PermissionsWindowController: NSWindowController, NSWindowDelegate {
    private let root: URL
    private let recording: URL?
    private let engine: TranscriptionEngineKind
    private let keyStore: ElevenLabsKeyStore
    private var labels: [PermissionsReport.Item: NSTextField] = [:]
    private var checks: [PermissionsReport.Item: Check] = [:]
    private var tasks: [PermissionsReport.Item: Task<Void, Never>] = [:]
    private var timer: Timer?
    private let summary = NSTextField(wrappingLabelWithString: "Checking access…")

    init(root: URL, recording: URL? = nil, engine: TranscriptionEngineKind? = nil,
         keyStore: ElevenLabsKeyStore = .shared) {
        self.root = root
        self.recording = recording
        self.engine = engine ?? TranscriptionEngineKind(rawValue: Config.transcriptionEngine()) ?? .parakeet
        self.keyStore = keyStore
        let availableHeight = (NSScreen.main?.visibleFrame.height ?? 950) - 60
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 740, height: min(availableHeight, recording == nil ? 790 : 870)),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Quill — Permissions & readiness"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildContent()
        window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show() {
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        refresh()
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
    }
    func windowWillClose(_ notification: Notification) { timer?.invalidate(); timer = nil }

    private func buildContent() {
        guard let content = window?.contentView else { return }
        let title = NSTextField(labelWithString: "Permissions & readiness")
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        let intro = NSTextField(wrappingLabelWithString: "Checks apply to this copy of Quill. Missing meeting or recording permissions do not prevent transcribing existing audio. Refreshing does not record or upload anything.")
        intro.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [title, intro, summary])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.distribution = .fill
        stack.spacing = 12
        for item in PermissionsReport.Item.allCases where item != .recording || recording != nil {
            let heading = NSTextField(labelWithString: item.rawValue)
            heading.font = .systemFont(ofSize: 13, weight: .semibold)
            let status = NSTextField(wrappingLabelWithString: "Checking…")
            status.font = .systemFont(ofSize: 12)
            labels[item] = status
            let details = NSStackView(views: [heading, status])
            details.orientation = .vertical; details.alignment = .leading; details.spacing = 3
            let button = NSButton(title: item == .folder || item == .recording ? "Open folder" : "Settings…", target: nil, action: nil)
            button.tag = PermissionsReport.Item.allCases.firstIndex(of: item)!
            button.target = self; button.action = #selector(actionClicked(_:))
            button.isHidden = item == .transcription
            button.widthAnchor.constraint(equalToConstant: 112).isActive = true
            let row = NSStackView(views: [details, button]); row.spacing = 16; row.alignment = .top
            row.distribution = .fill
            details.setContentHuggingPriority(.defaultLow, for: .horizontal)
            details.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            status.widthAnchor.constraint(equalTo: details.widthAnchor).isActive = true
        }
        let refresh = NSButton(title: "Check again", target: self, action: #selector(refreshClicked))
        stack.addArrangedSubview(refresh)
        for view in [intro, summary] { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        // Scroll on smaller displays instead of placing actions beyond the screen.
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        content.addSubview(scroll); scroll.translatesAutoresizingMaskIntoConstraints = false
        let document = PermissionsDocumentView()
        scroll.documentView = document; document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack); stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: content.topAnchor), scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -22),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -20)
        ])
    }

    @objc private func refreshClicked() { refresh() }
    private func refresh() {
        let mic = DoctorReport.checkMicrophone()
        set(.microphone, mic)
        set(.accessibility, Check(name: "accessibility", status: AXIsProcessTrusted() ? .ok : .warn("Access not granted"),
             remediation: "Used to detect meetings and read participant names from supported apps."))
        set(.screen, Check(name: "screen", status: CGPreflightScreenCaptureAccess() ? .ok : .warn("Screen access not granted"),
             remediation: "Used for Zoom speaker indicators. Enable Quill in Screen & System Audio Recording; a restart may be required."))
        set(.systemAudio, Check(name: "system audio", status: .warn("Not verified until recording starts"),
             remediation: "macOS has no passive check for Quill’s Core Audio tap permission. Screen access above does not verify audio access. Make a short test recording and check system.caf."))
        background(.folder) { [root] in PermissionsReport.folder(root) }
        if let recording { background(.recording) { PermissionsReport.recording(recording) } }
        background(.transcription) { [engine, keyStore] in
            PermissionsReport.transcription(engine: engine, access: engine == .elevenLabs ? keyStore.checkAccess() : .missing)
        }
        guard tasks[.notifications] == nil else { return }
        tasks[.notifications] = Task { [weak self] in
            let check: Check
            do {
                let status = try await NativeNotifications.shared.status()
                let authorized = ["authorized", "provisional"].contains(status["authorization"] as? String ?? "")
                let alerts = status["alerts_enabled"] as? Bool == true
                check = Check(name: "notifications", status: authorized && alerts ? .ok : .warn(authorized ? "Banners are disabled" : "Access not granted"),
                              remediation: "Recording and transcription alerts; processing can continue without them.")
            } catch { check = Check(name: "notifications", status: .warn(String(describing: error)), remediation: nil) }
            self?.tasks[.notifications] = nil; self?.set(.notifications, check)
        }
    }
    private func background(_ item: PermissionsReport.Item, _ work: @escaping @Sendable () -> Check) {
        guard tasks[item] == nil else { return }
        tasks[item] = Task { [weak self] in
            let check = await Task.detached(operation: work).value
            self?.tasks[item] = nil
            self?.set(item, check)
        }
    }
    private func set(_ item: PermissionsReport.Item, _ check: Check) {
        checks[item] = check
        let mark: String
        switch check.status {
        case .ok: mark = "✓ Available"
        case .warn(let message): mark = "! " + message
        case .fail(let message): mark = "✗ " + message
        }
        labels[item]?.stringValue = mark + (check.remediation.map { "\n" + $0 } ?? "")
        labels[item]?.textColor = { if case .fail = check.status { return .systemRed }; return .secondaryLabelColor }()
        let failures = checks.values.filter { if case .fail = $0.status { return true }; return false }.count
        summary.stringValue = failures > 0 ? "\(failures) check(s) need attention. See the details below." : "Review the warnings below; some access can only be verified during use."
    }
    @objc private func actionClicked(_ sender: NSButton) {
        let item = PermissionsReport.Item.allCases[sender.tag]
        if item == .folder || item == .recording { NSWorkspace.shared.open(item == .recording ? recording! : root); return }
        Task {
            switch item {
            case .microphone:
                if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined { _ = await AVCaptureDevice.requestAccess(for: .audio) }
            case .accessibility:
                _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
            case .screen: _ = CGRequestScreenCaptureAccess()
            case .notifications: try? await NativeNotifications.shared.authorize()
            default: break
            }
            let pane: String
            switch item {
            case .microphone: pane = "com.apple.preference.security?Privacy_Microphone"
            case .accessibility: pane = "com.apple.preference.security?Privacy_Accessibility"
            case .notifications: pane = "com.apple.Notifications-Settings.extension"
            default: pane = "com.apple.preference.security?Privacy_ScreenCapture"
            }
            if let url = URL(string: "x-apple.systempreferences:" + pane) { NSWorkspace.shared.open(url) }
            refresh()
        }
    }
}

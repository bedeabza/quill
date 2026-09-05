import AppKit
@preconcurrency import ApplicationServices

@MainActor
final class MeetingAssistant {
    var onStart: (() -> Bool)?
    var onStop: (() -> Void)?
    var onStatus: ((String, Bool) -> Void)?
    private var policy = MeetingPolicy()
    private let scanner = MeetingScanner()
    private var timer: Timer?
    private var scanning = false
    private var panel: NSPanel?
    private var panelLabel: NSTextField?
    private var panelKind: String?
    private var enabled = Config.meetingDetection()
    private var lastStatus: String?

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        poll()
    }

    func shutdown() {
        timer?.invalidate()
        timer = nil
        closePanel()
    }

    func toggleEnabled() {
        guard Config.setMeetingDetection(!enabled) else {
            notifyUser(title: "Quill settings", body: "Could not save the meeting detection setting. Check the configuration file.")
            return
        }
        enabled.toggle()
        if !enabled { policy.keepRecording(); closePanel() }
        if enabled && !AXIsProcessTrusted() { requestPermission() }
        poll()
    }

    func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func recordingStarted() {
        policy.recordingStarted(for: policy.pendingPrompt)
        closePanel()
    }

    func recordingStopped() {
        policy.recordingStopped()
        closePanel()
    }

    func keepRecording() {
        policy.keepRecording()
        closePanel()
        report("Automatic stop off for this recording", enabled)
    }

    private func report(_ text: String, _ enabled: Bool) {
        if text != lastStatus {
            FileHandle.standardError.write(Data("meeting detection: \(text)\n".utf8))
            lastStatus = text
        }
        onStatus?(text, enabled)
    }

    private func poll() {
        guard enabled else {
            report("Meeting detection off", false)
            return
        }
        guard !scanning else { return }
        scanning = true
        let apps = MeetingApp.running()
        Task { [weak self, scanner] in
            let scan = await scanner.scan(apps: apps)
            guard let self else { return }
            self.scanning = false
            guard self.enabled else { return }
            let action = self.policy.update(scan.observations, now: ProcessInfo.processInfo.systemUptime)
            if scan.needsPermission {
                self.closePanel()
                self.report("Meeting detection needs Accessibility permission", true)
                return
            } else if let meeting = self.policy.recordingMeeting {
                self.report("Watching \(meeting.service) in \(meeting.app)", true)
            } else if self.policy.recording {
                self.report(self.policy.automaticStop ? "No meeting linked; stop recording manually" : "Automatic stop off for this recording", true)
            } else {
                self.report("Meeting detection on", true)
            }
            switch action {
            case .prompt(let meeting):
                self.showPanel(kind: "start:\(meeting.id)", text: "\(meeting.service) detected in \(meeting.app).\nStart recording this meeting?", primary: "Start recording", secondary: "Not now")
            case .countdown(let seconds):
                self.showPanel(kind: "stop", text: "The meeting ended.\nRecording stops in \(seconds) seconds.", primary: "Keep recording", secondary: "Stop now")
            case .stop:
                self.closePanel()
                self.onStop?()
                notifyUser(title: "Quill recording stopped", body: "The meeting ended. Your recording is being transcribed.")
            case .unavailable:
                self.closePanel()
                self.report("Meeting status unavailable; recording continues", true)
            case .none:
                self.closePanel()
            }
        }
    }

    private func showPanel(kind: String, text: String, primary: String, secondary: String) {
        if panelKind == kind { panelLabel?.stringValue = text; return }
        closePanel()
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 156),
                            styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Quill"
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let label = NSTextField(wrappingLabelWithString: text)
        label.frame = NSRect(x: 20, y: 62, width: 360, height: 68)
        label.font = .systemFont(ofSize: 14)
        panel.contentView?.addSubview(label)
        let first = NSButton(title: primary, target: self, action: #selector(primaryClicked))
        first.frame = NSRect(x: 214, y: 16, width: 165, height: 32)
        first.bezelStyle = .rounded
        let second = NSButton(title: secondary, target: self, action: #selector(secondaryClicked))
        second.frame = NSRect(x: 20, y: 16, width: 165, height: 32)
        second.bezelStyle = .rounded
        panel.contentView?.addSubview(first)
        panel.contentView?.addSubview(second)
        panel.center()
        panel.orderFrontRegardless()
        FileHandle.standardError.write(Data("meeting detection: \(kind == "stop" ? "stop countdown" : "start prompt") shown\n".utf8))
        self.panel = panel
        panelLabel = label
        panelKind = kind
    }

    private func closePanel() {
        panel?.close()
        panel = nil
        panelLabel = nil
        panelKind = nil
    }

    @objc private func primaryClicked() {
        if panelKind == "stop" { keepRecording() }
        else if onStart?() != true { policy.dismissPrompt(); closePanel() }
    }

    @objc private func secondaryClicked() {
        if panelKind == "stop" { onStop?() }
        else { policy.dismissPrompt(); closePanel() }
    }
}

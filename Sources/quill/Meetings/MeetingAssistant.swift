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
    private var bannerTimer: Timer?
    private var automaticStart: DetectedMeeting?
    private var enabled = Config.meetingDetection()
    private var lastStatus: String?

    func start() {
        _ = policy.setAutomationEnabled(enabled)
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
        if policy.setAutomationEnabled(enabled) == .stop { onStop?() }
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
        policy.recordingStarted(for: automaticStart, automatic: automaticStart != nil)
        showBanner(title: "Recording started", body: automaticStart.map { "\($0.service) in \($0.app)" } ?? "Recording microphone and system audio.")
    }

    func recordingStopped() {
        policy.recordingStopped()
        showBanner(title: "Recording stopped", body: "Your recording is being prepared for transcription.")
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
            case .start(let meeting):
                self.automaticStart = meeting
                if self.onStart?() != true { self.policy.startFailed(for: meeting) }
                self.automaticStart = nil
            case .countdown(let seconds):
                self.report("Meeting ended; stopping automatically in \(seconds)s", true)
            case .stop:
                self.onStop?()
            case .unavailable:
                self.report("Meeting status unavailable; recording continues", true)
            case .none:
                break
            }
        }
    }

    private func showBanner(title: String, body: String) {
        closePanel()
        let size = NSSize(width: 370, height: 92)
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Quill"
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let content = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        content.material = .hudWindow
        content.state = .active
        content.wantsLayer = true
        content.layer?.cornerRadius = 14
        content.layer?.masksToBounds = true
        let heading = NSTextField(labelWithString: "Quill: " + title)
        heading.font = .boldSystemFont(ofSize: 14)
        heading.frame = NSRect(x: 18, y: 57, width: 334, height: 20)
        let detail = NSTextField(wrappingLabelWithString: body)
        detail.font = .systemFont(ofSize: 12)
        detail.frame = NSRect(x: 18, y: 14, width: 334, height: 36)
        content.addSubview(heading)
        content.addSubview(detail)
        panel.contentView = content
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.maxX - size.width - 16, y: frame.maxY - size.height - 12))
        }
        panel.orderFrontRegardless()
        FileHandle.standardError.write(Data("meeting detection: \(title.lowercased()) banner shown\n".utf8))
        self.panel = panel
        bannerTimer = Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.closePanel() }
        }
    }

    private func closePanel() {
        bannerTimer?.invalidate()
        bannerTimer = nil
        panel?.close()
        panel = nil
    }
}

import AppKit
@preconcurrency import ApplicationServices

@MainActor
final class MeetingAssistant {
    var onStart: (() -> Bool)?
    var onStop: (() -> Void)?
    var onStatus: ((String, Bool) -> Void)?
    var onSpeakers: ((SpeakerObservation) -> Void)?
    private var policy = MeetingPolicy()
    private let scanner = MeetingScanner()
    private var timer: Timer?
    private var scanning = false
    private let recordingNotification: (String, String) -> Void
    private var automaticStart: DetectedMeeting?
    private var enabled = Config.meetingDetection()
    private var lastStatus: String?

    init(recordingNotification: @escaping (String, String) -> Void = notifyUser) {
        self.recordingNotification = recordingNotification
    }

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
        recordingNotification("Quill: Recording started", automaticStart.map { "\($0.service) in \($0.app)" } ?? "Recording microphone and system audio.")
    }

    func recordingStopped() {
        policy.recordingStopped()
        recordingNotification("Quill: Recording stopped", "Your recording is being prepared for transcription.")
    }

    func keepRecording() {
        policy.keepRecording()
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
            let recordingSpeakers = self?.policy.recording == true && Config.speakerDetection()
            let scan = await scanner.scan(apps: apps, captureSpeakers: recordingSpeakers,
                                          enableCaptions: recordingSpeakers && Config.autoMeetingCaptions(),
                                          captionMeetingID: self?.policy.recordingMeeting?.id)
            guard let self else { return }
            self.scanning = false
            guard self.enabled else { return }
            let action = self.policy.update(scan.observations, now: ProcessInfo.processInfo.systemUptime)
            if let meeting = self.policy.recordingMeeting, let names = scan.speakers[meeting.id] {
                self.onSpeakers?(SpeakerObservation(observed_at: scan.speakerObservedAt[meeting.id] ?? scan.observedAt,
                                                    meeting_id: meeting.id, names: names))
            }
            for caption in scan.captions where caption.meeting_id == self.policy.recordingMeeting?.id {
                self.onSpeakers?(caption)
            }
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

}

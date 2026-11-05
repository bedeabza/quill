import AppKit
@preconcurrency import ApplicationServices
import AVFoundation
import Observation

/// Permission and readiness checks for the Permissions section. Checks run
/// inside the app so macOS evaluates Quill's identity; a refresh never
/// records, uploads or prompts.
@Observable @MainActor
final class PermissionsModel {
    /// Rows in display order.
    let items: [PermissionsReport.Item] = PermissionsReport.Item.allCases.filter { $0 != .recording }
    /// Latest result per row; a missing row is still being checked.
    private(set) var checks: [PermissionsReport.Item: Check] = [:]
    /// Rows needing attention, for the sidebar badge.
    var attentionCount: Int { Self.attentionCount(checks) }
    /// Folder checked by the folder row.
    let root: URL

    @ObservationIgnored private let keyStore: ElevenLabsKeyStore
    @ObservationIgnored private var tasks: [PermissionsReport.Item: Task<Void, Never>] = [:]
    @ObservationIgnored private var timer: Timer?

    init(root: URL, keyStore: ElevenLabsKeyStore = .shared) {
        self.root = root
        self.keyStore = keyStore
    }

    /// Check now and every 3 s until `stop()`. Call while the section is visible.
    func start() {
        refresh()
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func stop() { timer?.invalidate(); timer = nil }

    func refresh() {
        checks[.microphone] = DoctorReport.checkMicrophone()
        checks[.accessibility] = Check(name: "accessibility", status: AXIsProcessTrusted() ? .ok : .warn("Access not granted"),
            remediation: "Used to detect meetings and read participant names from supported apps.")
        checks[.screen] = Check(name: "screen", status: CGPreflightScreenCaptureAccess() ? .ok : .warn("Screen access not granted"),
            remediation: "Used for Zoom speaker indicators. Enable Quill in Screen & System Audio Recording; a restart may be required.")
        checks[.systemAudio] = Check(name: "system audio", status: .warn("Not verified until recording starts"),
            remediation: "macOS has no passive check for Quill’s Core Audio tap permission. Screen access above does not verify audio access. Make a short test recording and check system.caf.")
        background(.folder) { [root] in PermissionsReport.folder(root) }
        let engine = TranscriptionEngineKind(rawValue: Config.transcriptionEngine()) ?? .parakeet
        background(.transcription) { [keyStore] in
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
            self?.tasks[.notifications] = nil
            self?.checks[.notifications] = check
        }
    }

    /// Button title for a row, or nil when it is fine or has nothing to do.
    /// System audio has no check to act on until a recording starts.
    func actionTitle(_ item: PermissionsReport.Item) -> String? {
        guard let check = checks[item], item != .transcription, item != .systemAudio else { return nil }
        if case .ok = check.status { return nil }
        return item == .folder ? "Open Folder" : "Open Settings…"
    }

    /// Opens the folder, or asks macOS for access where it can still prompt and
    /// then opens the matching System Settings pane.
    func perform(_ item: PermissionsReport.Item) {
        if item == .folder { NSWorkspace.shared.open(root); return }
        guard item != .transcription, item != .recording else { return }
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

    /// Failures and warnings, except the system audio warning that no check can clear.
    static func attentionCount(_ checks: [PermissionsReport.Item: Check]) -> Int {
        checks.filter { item, check in
            switch check.status {
            case .ok: return false
            case .warn: return item != .systemAudio
            case .fail: return true
            }
        }.count
    }

    private func background(_ item: PermissionsReport.Item, _ work: @escaping @Sendable () -> Check) {
        guard tasks[item] == nil else { return }
        tasks[item] = Task { [weak self] in
            let check = await Task.detached(operation: work).value
            self?.tasks[item] = nil
            self?.checks[item] = check
        }
    }
}

import Foundation
import Observation

/// Live status shared by the menu and the main window. `AppController`
/// updates it and sets the actions.
@Observable @MainActor
final class AppState {
    var recording = false
    /// "0:00" style counter while recording, nil when idle.
    var elapsed: String?
    /// Second status line, e.g. "Transcribing 2026.11.02-1000 · 1 queued"; nil when idle.
    var transcriptionStatus: String?
    var detectionText = "Meeting detection on"
    var detectionEnabled = false

    /// Meeting detection is blocked on a permission; offer `requestMeetingPermission`.
    var needsMeetingPermission: Bool { detectionText.contains("permission") }
    /// Label for the permission action: Zoom speaker names need Screen Recording.
    var meetingPermissionTitle: String {
        detectionText.contains("Screen Recording") ? "Allow Zoom speaker names..." : "Allow meeting detection..."
    }

    @ObservationIgnored var toggleRecording: () -> Void = {}
    /// Turns automatic meeting recording on or off; `detectionEnabled` follows.
    @ObservationIgnored var toggleDetection: () -> Void = {}
    /// Keeps the current recording running after its meeting ends.
    @ObservationIgnored var keepRecording: () -> Void = {}
    @ObservationIgnored var requestMeetingPermission: () -> Void = {}

    static func transcriptionText(_ status: TranscriptionCoordinator.Status) -> String? {
        switch status {
        case .idle: return nil
        case .transcribing(let name, let queued): return "Transcribing \(name)" + (queued > 0 ? " · \(queued) queued" : "")
        case .postprocessing(let name, let queued): return "Cleaning transcript \(name)" + (queued > 0 ? " · \(queued) queued" : "")
        case .failed(let name): return "Transcription failed · \(name)"
        }
    }
}

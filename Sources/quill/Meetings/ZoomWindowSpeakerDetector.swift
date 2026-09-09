import CoreGraphics
import Foundation
@preconcurrency import ScreenCaptureKit

struct ZoomSpeakerSample: Sendable {
    let observedAt: Double
    let names: [String]
    let scores: [String: Double]
}

/// Reads only the identified Zoom meeting window. Frames are discarded after
/// sampling tile-border pixels. Participant video is never saved or uploaded.
actor ZoomWindowSpeakerDetector {
    private var window: SCWindow?
    private var meetingID: String?
    private var lastCapture = 0.0
    private(set) var diagnostic = "idle"
    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    func sample(meetingID: String, pid: pid_t, frame: CGRect, videos: [ZoomVideoSnapshot]) async -> ZoomSpeakerSample? {
        if self.meetingID != meetingID { self.meetingID = meetingID; window = nil; lastCapture = 0 }
        guard Config.zoomVisualSpeakerDetection() else { diagnostic = "Zoom visual speaker names disabled"; return nil }
        guard Self.hasPermission else { diagnostic = "Screen Recording permission required"; return nil }
        guard videos.contains(where: \.isLocal) else { diagnostic = "Zoom self tile is not identified; speaker names withheld"; return nil }
        guard !videos.isEmpty, frame.width.isFinite, frame.height.isFinite, frame.minX.isFinite, frame.minY.isFinite,
              frame.width > 0, frame.height > 0, frame.width <= 10000, frame.height <= 10000 else { return nil }
        let started = Date().timeIntervalSince1970
        guard started - lastCapture >= 0.4 else { return nil }
        lastCapture = started
        do {
            if window?.owningApplication?.processID != pid || window.map({ !Self.sameFrame($0.frame, frame) }) != false {
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                let matches = content.windows.filter { $0.owningApplication?.processID == pid && $0.title == "Zoom Meeting" && Self.sameFrame($0.frame, frame) }
                guard matches.count == 1 else { diagnostic = "No unique Zoom window matches the accessibility frame"; window = nil; return nil }
                window = matches[0]
            }
            guard let window else { return nil }
            let info = CGWindowListCopyWindowInfo(.optionIncludingWindow, window.windowID) as? [[String: Any]]
            guard info?.first?[kCGWindowIsOnscreen as String] as? Bool == true else {
                if info?.isEmpty != false { self.window = nil }
                diagnostic = "Zoom window is not on screen"
                return nil
            }
            let configuration = SCStreamConfiguration()
            configuration.width = Int(frame.width.rounded())
            configuration.height = Int(frame.height.rounded())
            configuration.showsCursor = false
            configuration.capturesAudio = false
            configuration.ignoreShadowsSingleWindow = true
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            let ended = Date().timeIntervalSince1970
            guard ended - started <= 0.7 else { diagnostic = "Discarded slow window capture"; return nil }
            let width = image.width, height = image.height
            guard let pixels = ZoomSpeakerEvidence.rgbaPixels(image) else { return nil }
            let sx = Double(width) / frame.width, sy = Double(height) / frame.height
            var scores: [String: Double] = [:]
            var active: [String] = []
            for video in videos {
                let rect = CGRect(x: (video.frame.minX - frame.minX) * sx, y: (video.frame.minY - frame.minY) * sy,
                                  width: video.frame.width * sx, height: video.frame.height * sy)
                let score = ZoomSpeakerEvidence.borderScore(rgba: pixels, width: width, height: height, rect: rect)
                scores[video.name] = score
                if !video.isLocal && !video.muted && score >= 0.65 { active.append(video.name) }
            }
            guard Set(videos.map(\.name)).count == videos.count else { return nil }
            diagnostic = "Zoom window borders sampled locally"
            return ZoomSpeakerSample(observedAt: (started + ended) / 2, names: active, scores: scores)
        } catch {
            diagnostic = "Zoom window capture unavailable: \(error.localizedDescription)"
            window = nil
            return nil
        }
    }

    private static func sameFrame(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) < 3 && abs(lhs.minY - rhs.minY) < 3
            && abs(lhs.width - rhs.width) < 3 && abs(lhs.height - rhs.height) < 3
    }
}

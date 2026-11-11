import AVFoundation
import Foundation

/// Time the microphone was not recorded, on the meeting clock (seconds from
/// `audio_started_at`, like transcript timestamps). New recordings keep every
/// gap in `meta.json` as `microphone_gaps`; for older ones only an early stop
/// is visible, from the length of `mic.caf`.
enum MicrophoneGaps {
    /// Shorter gaps (an input switching over) are logged but not shown.
    static let noticeable = 5.0

    static func read(in directory: URL) -> [MicTrack.Gap] {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("meta.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        if let stored = json["microphone_gaps"] as? [[String: Double]] {
            return stored.compactMap { gap in gap["start"].flatMap { start in gap["end"].map { MicTrack.Gap(start: start, end: $0) } } }
        }
        guard let duration = json["duration_seconds"] as? Double,
              let mic = (json["files"] as? [String: String])?["mic"],
              let file = try? AVAudioFile(forReading: directory.appendingPathComponent(mic)) else { return [] }
        let offset = Double((json["start_offset_ms"] as? [String: Int])?["mic"] ?? 0) / 1000
        let end = offset + Double(file.length) / file.processingFormat.sampleRate
        return duration - end >= noticeable ? [MicTrack.Gap(start: end, end: duration)] : []
    }

    /// One line for the Recordings detail; nil when no gap is noticeable.
    static func notice(_ gaps: [MicTrack.Gap], duration: Int?) -> String? {
        let shown = gaps.filter { $0.end - $0.start >= noticeable }
        guard let first = shown.first else { return nil }
        if shown.count == 1, let duration, Double(duration) - first.end < noticeable {
            return "Microphone stopped at \(clock(first.start)). Your voice after that wasn’t recorded."
        }
        let spans = shown.prefix(3).map { "\(clock($0.start))–\(clock($0.end))" }.joined(separator: ", ")
            + (shown.count > 3 ? " and \(shown.count - 3) more" : "")
        return "Microphone not recorded \(spans). Your voice in that time wasn’t recorded."
    }

    /// Every gap, for transcribe.log.
    static func log(_ gaps: [MicTrack.Gap]) -> String {
        "microphone not recorded (meeting clock): " + gaps.map { String(format: "%.1f–%.1f s", $0.start, $0.end) }.joined(separator: ", ")
    }

    /// "6:27", "1:02:05".
    static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        let h = total / 3600, m = total / 60 % 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

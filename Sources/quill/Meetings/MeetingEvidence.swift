import Foundation

/// Once a visible meeting has ended, keeping its tab open must not restart
/// recording when that tab moves into the background.
struct MeetingEndState {
    private var ended: Set<String> = []

    mutating func isEnded(_ id: String, endScreen: Bool, inCall: Bool) -> Bool {
        if inCall { ended.remove(id) }
        else if endScreen { ended.insert(id) }
        return ended.contains(id)
    }

    mutating func forget(_ id: String) { ended.remove(id) }
}

enum MeetingEvidence {
    /// Titles are taken only from an already identified meeting's own surface.
    /// Generic app names, URLs and room codes are not meeting subjects.
    static func title(candidates: [String], service: String) -> String? {
        for candidate in candidates {
            var title = candidate.components(separatedBy: .controlCharacters).joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let separators = [" - ", " – ", " — ", " | "]
            let prefixes = separators.flatMap { ["Google Meet" + $0, "Meet" + $0] }
                + ["Meeting:", "Meeting title:", "Meeting name:", "Meeting topic:"]
            for prefix in prefixes {
                if title.lowercased().hasPrefix(prefix.lowercased()) { title = String(title.dropFirst(prefix.count)) }
            }
            for suffix in separators.flatMap({ separator in ["Google Meet", "Microsoft Teams", "Zoom", "Slack"].map { separator + $0 } }) {
                if title.lowercased().hasSuffix(suffix.lowercased()) { title = String(title.dropLast(suffix.count)) }
            }
            title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            let generic = [service.lowercased(), "meet", "google meet", "microsoft teams", "teams", "zoom", "zoom meeting", "slack", "huddle", "web content"]
            guard !title.isEmpty, title.count <= 500, !generic.contains(title.lowercased()),
                  !title.contains("://"),
                  title.range(of: "^[a-z]{3}-[a-z]{4}-[a-z]{3}$", options: [.regularExpression, .caseInsensitive]) == nil else { continue }
            return title
        }
        return nil
    }

    static func nativeService(bundleID: String) -> String? {
        switch bundleID.lowercased() {
        case "us.zoom.xos": return "Zoom"
        case "com.microsoft.teams2", "com.microsoft.teams": return "Microsoft Teams"
        case "com.tinyspeck.slackmacgap": return "Slack"
        default: return nil
        }
    }

    static func isZoomConferenceWindow(title: String, videoLabels: [String]) -> Bool {
        title == "Zoom Meeting" && videoLabels.contains {
            $0.range(of: #", (?:Computer|Phone) audio (?:unmuted|muted)(?:,|$)"#, options: .regularExpression) != nil
        }
    }

    static func meetCode(in text: String) -> String? {
        let lower = text.lowercased()
        guard lower.contains("meet") else { return nil }
        guard let range = lower.range(of: "(?<![a-z])[a-z]{3}-[a-z]{4}-[a-z]{3}(?![a-z])", options: .regularExpression) else { return nil }
        return String(lower[range])
    }

    static func service(url: String) -> String? {
        guard let parsed = URL(string: url), let host = parsed.host?.lowercased() else { return nil }
        if host == "meet.google.com", parsed.path.range(of: "^/(?:meet/)?[a-z]{3}-[a-z]{4}-[a-z]{3}/?$", options: .regularExpression) != nil { return "Google Meet" }
        if host == "teams.microsoft.com" || host == "teams.live.com" || host == "teams.cloud.microsoft" { return "Microsoft Teams" }
        if host == "zoom.us" || host.hasSuffix(".zoom.us") { return "Zoom" }
        if ["https", "http"].contains(parsed.scheme?.lowercased() ?? ""),
           host.hasSuffix(".slack.com"),
           parsed.path.range(of: "^/(client|huddle|messages|archives)(/|$)", options: .regularExpression) != nil { return "Slack" }
        return nil
    }

    static func isLeaveControl(_ text: String) -> Bool {
        let text = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return ["leave call", "leave meeting", "end meeting", "hang up", "end call"]
            .contains { text == $0 || text.hasPrefix($0 + " ") || text.hasPrefix($0 + "(") }
    }

    static func hasCallControls(_ buttons: [String]) -> Bool {
        if buttons.contains(where: isLeaveControl) { return true }
        let normalized = buttons.map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
        let hasLeave = normalized.contains { $0 == "leave" || $0 == "end" }
        let hasAudio = normalized.contains { $0.hasPrefix("mute") || $0.hasPrefix("unmute") || $0.hasPrefix("turn off microphone") || $0.hasPrefix("turn on microphone") }
        return hasLeave && hasAudio
    }

    static func isEndMessage(_ text: String) -> Bool {
        let text = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return ["you left the meeting", "you've left the meeting", "you have left the meeting",
                "the meeting has ended", "this meeting has ended", "your call has ended",
                "you left the call", "you've left the call", "the host has ended this meeting"]
            .contains { text == $0 || text.hasPrefix($0 + ".") }
    }
}

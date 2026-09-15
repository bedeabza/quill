import Foundation

/// Slack keeps its chat window open after a huddle. Only joined controls can
/// start capture; a complete, visible return to start/join controls can end it.
enum SlackHuddleEvidence {
    enum State: Equatable { case joined, ended, unknown }

    static func isControl(role: String) -> Bool {
        ["AXButton", "AXCheckBox", "AXSwitch", "AXPopUpButton"].contains(role)
    }

    static func hasJoinedControls(_ controls: [String]) -> Bool {
        if controls.contains(where: { matches($0, labels: ["leave huddle", "leave the huddle", "end huddle"]) }) {
            return true
        }
        // Slack's expanded huddle uses a plain Leave button. Do not confuse
        // channel navigation plus Mute conversation/notifications with a call.
        let leave = controls.contains { matches($0, labels: ["leave", "hang up", "leave call", "end call"]) }
        let microphone = controls.contains {
            matches($0, labels: ["mute", "unmute", "mute microphone", "unmute microphone",
                                "mute your microphone", "unmute your microphone", "mute mic", "unmute mic",
                                "turn off microphone", "turn on microphone"])
        }
        return leave && microphone
    }

    static func state(controls: [String], complete: Bool, visible: Bool) -> State {
        guard visible else { return .unknown }
        if hasJoinedControls(controls) { return .joined }
        guard complete else { return .unknown }
        let idle = controls.contains {
            let text = $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            return matches(text, labels: ["start huddle", "start a huddle", "join huddle", "join the huddle", "rejoin huddle"])
                || ["start huddle with ", "start huddle in ", "join huddle with ", "join huddle in "]
                    .contains(where: text.hasPrefix)
        }
        return idle ? .ended : .unknown
    }

    private static func matches(_ text: String, labels: [String]) -> Bool {
        let text = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return labels.contains { text == $0 || text.hasPrefix($0 + " (") || text.hasPrefix($0 + "(") }
    }
}

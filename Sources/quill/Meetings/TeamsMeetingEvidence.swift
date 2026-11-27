import Foundation

/// Teams web exposes split buttons and microphone toggles through Chromium AX.
/// Evaluate only one Teams document: another tab's controls cannot start a call.
enum TeamsMeetingEvidence {
    enum State: Equatable { case joined, ended, unknown }
    struct Control {
        let role: String
        let labels: [String]
    }

    static func isControl(role: String) -> Bool {
        ["AXButton", "AXPopUpButton", "AXCheckBox", "AXSwitch", "AXToggleButton"].contains(role)
    }

    static func isTeamsURL(_ url: String) -> Bool {
        URL(string: url)?.scheme?.lowercased() == "https" && MeetingEvidence.service(url: url) == "Microsoft Teams"
    }

    static func state(url: String, controls: [Control], texts: [String] = [], complete: Bool, visible: Bool) -> State {
        guard visible, isTeamsURL(url) else { return .unknown }
        let labels = controls.filter { isControl(role: $0.role) }.flatMap(\.labels).map(normalized)
        let join = labels.contains { matches($0, labels: ["join now", "rejoin", "rejoin meeting", "join meeting",
            "asociati-va acum", "asociere acum", "participati acum", "participa acum", "alaturati-va acum",
            "alaturati-va intalnirii", "alaturati-va la intalnire", "reparticipati", "reasociere", "reasociati-va", "reconectare", "participati din nou"]) }
        let lobby = texts.map(normalized).contains { message($0, startsWith: [
            "someone in the meeting should let you in soon", "wait for someone to let you in",
            "when the meeting starts, we'll let people know you're waiting",
            "cineva din intalnire ar trebui sa va permita accesul in curand",
            "asteptati ca cineva sa va permita accesul", "asteptati in sala de asteptare"
        ]) }
        if lobby { return complete ? .ended : .unknown }

        let explicitLeave = labels.contains { matches($0, labels: ["leave call", "leave meeting", "hang up", "end call", "end meeting",
            "parasiti intalnirea", "paraseste intalnirea", "parasiti apelul", "iesiti din intalnire",
            "iesire din intalnire", "inchideti apelul", "incheiati apelul", "incheiere apel", "terminare apel"]) }
        let leave = explicitLeave || labels.contains { matches($0, labels: ["leave", "end", "parasiti", "paraseste", "iesire", "iesiti"]) }
        let microphone = labels.contains { matches($0, labels: ["mic", "microphone", "mute mic", "unmute mic", "mute microphone",
            "unmute microphone", "mute your microphone", "unmute your microphone", "turn off microphone", "turn on microphone",
            "microfon", "activati microfonul", "dezactivati microfonul", "activare microfon", "dezactivare microfon",
            "porniti microfonul", "opriti microfonul"]) }
        let mute = labels.contains { matches($0, labels: ["mute", "unmute", "activare sunet", "dezactivare sunet",
            "activati sunetul", "dezactivati sunetul", "reactivati sunetul", "reactivare sunet"]) }
        let camera = labels.contains { matches($0, labels: ["camera", "turn on camera", "turn off camera", "camera video",
            "activati camera", "dezactivati camera", "porniti camera", "opriti camera"]) }
        // Microsoft's Romanian screen-reader guide calls Hang up "Închideți".
        // That also means Close, so require an additional in-call action.
        let close = labels.contains { matches($0, labels: ["inchideti"]) }
        let meetingTool = labels.contains { matches($0, labels: ["show participants", "raise hand", "lower hand",
            "afisare participanti", "afisati participantii", "ridicati mana", "coborati mana", "afisare conversatie"]) }
        let qualifiedClose = close && meetingTool && !join
        if (leave || qualifiedClose) && (microphone || (mute && (explicitLeave || camera || qualifiedClose))) { return .joined }
        if join { return complete ? .ended : .unknown }
        guard complete else { return .unknown }
        let ended = texts.map(normalized).contains { message($0, startsWith: [
            "you left the meeting", "you've left the meeting", "you have left the meeting", "the meeting has ended",
            "this meeting has ended", "your call has ended", "you left the call", "the host has ended this meeting",
            "ati parasit intalnirea", "ai parasit intalnirea", "intalnirea s-a incheiat", "aceasta intalnire s-a incheiat",
            "apelul s-a incheiat", "ati parasit apelul", "organizatorul a incheiat intalnirea"
        ]) }
        return ended ? .ended : .unknown
    }

    private static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "’", with: "'")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Match complete labels or keyboard-shortcut suffixes, never arbitrary prose
    /// such as Leave a comment, Leave chat or Mute notifications.
    private static func matches(_ text: String, labels: [String]) -> Bool {
        labels.contains { label in
            if text == label { return true }
            guard text.hasPrefix(label) else { return false }
            let suffix = text.dropFirst(label.count).trimmingCharacters(in: .whitespaces)
            guard (suffix.hasPrefix("(") && suffix.hasSuffix(")")) || (suffix.hasPrefix("[") && suffix.hasSuffix("]")) else { return false }
            return ["ctrl", "control", "command", "cmd", "shift", "alt", "option", "⌘", "⇧", "⌥", "⌃"].contains { suffix.contains($0) }
        }
    }

    private static func message(_ text: String, startsWith labels: [String]) -> Bool {
        labels.contains { text == $0 || text.hasPrefix($0 + ".") || text.hasPrefix($0 + "!") }
    }
}

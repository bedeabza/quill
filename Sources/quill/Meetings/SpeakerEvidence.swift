import Foundation

/// Parse explicit activity labels only. An unmuted microphone, participant
/// roster, pinned tile, or caption mentioning a person is not speaking evidence.
enum SpeakerEvidence {
    /// Google Meet's live AX structure, observed in Brave: a named Captions
    /// group containing blocks whose first static text is the speaker label.
    static func caption(texts: [String], meetingID: String, observedAt: Double) -> SpeakerObservation? {
        guard texts.count >= 2, let label = texts.first else { return nil }
        let isLocal = label == "You" || label == "Tu"
        guard isLocal || SpeakerAttribution.cleanName(label) != nil else { return nil }
        let text = texts.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 4000 else { return nil }
        return SpeakerObservation(observed_at: observedAt, meeting_id: meetingID, names: [label],
                                  source: "meeting_caption", text: text, is_local: isLocal)
    }

    static func activeName(label: String, role: String) -> String? {
        guard ["AXGroup", "AXImage", "AXCell", "AXButton"].contains(role) else { return nil }
        let patterns = [#"^(.+?) is speaking$"#, #"^(.+?), speaking$"#, #"^Speaking: (.+)$"#,
                        #"^(.+?) vorbește$"#, #"^Vorbește: (.+)$"#]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                  let match = regex.firstMatch(in: label, range: NSRange(label.startIndex..., in: label)),
                  let range = Range(match.range(at: 1), in: label) else { continue }
            return SpeakerAttribution.cleanName(String(label[range]))
        }
        return nil
    }
}

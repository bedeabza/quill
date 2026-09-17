import Foundation

/// App-lifetime UI state. No audio or historical speaking activity is collected
/// outside recordings. Only a fresh roster may seed a newly started recording.
struct SpeakerTrackingState {
    private(set) var meetingIDs: [String] = []
    private var rosters: [String: SpeakerObservation] = [:]

    mutating func update(_ observations: [String: MeetingObservation], at now: Double) {
        meetingIDs = observations.compactMap { id, state in
            if case .present = state { return id }
            return nil
        }.sorted()
        rosters = rosters.filter { id, roster in
            observations[id] != .ended && now - roster.observed_at <= 15
        }
    }

    func recordingMeetingID(preferred: String?, previous: String?) -> String? {
        if let preferred, meetingIDs.contains(preferred) { return preferred }
        if let previous, meetingIDs.contains(previous) { return previous }
        return meetingIDs.count == 1 ? meetingIDs[0] : nil
    }

    mutating func observe(_ observation: SpeakerObservation) {
        guard observation.source == "meeting_roster",
              observation.observed_at >= (rosters[observation.meeting_id]?.observed_at ?? -.infinity) else { return }
        rosters[observation.meeting_id] = observation
    }

    func seed(meetingID: String, at now: Double) -> SpeakerObservation? {
        guard let roster = rosters[meetingID], now >= roster.observed_at,
              now - roster.observed_at <= 5 else { return nil }
        return SpeakerObservation(observed_at: now, meeting_id: meetingID, names: [], source: "meeting_roster",
                                  participants: roster.participants, participant_count: roster.participant_count,
                                  roster_complete: roster.roster_complete)
    }
}

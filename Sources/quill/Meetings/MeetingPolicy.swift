import Foundation

struct DetectedMeeting: Equatable, Sendable {
    let id: String
    let app: String
    let service: String
}

enum MeetingObservation: Equatable, Sendable {
    case present(DetectedMeeting)
    case ended
    case unknown
}

/// Missing or unreadable observations never authorize stopping audio capture.
struct MeetingPolicy {
    enum Action: Equatable {
        case none, start(DetectedMeeting), countdown(Int), stop, unavailable
    }

    private(set) var recordingMeeting: DetectedMeeting?
    private(set) var recording = false
    private(set) var automaticStop = true
    private var automationEnabled = true
    private var automaticRecording = false
    private var endedAt: TimeInterval?
    private var dismissed: Set<String> = []

    mutating func update(_ observations: [String: MeetingObservation], now: TimeInterval) -> Action {
        guard automationEnabled else { return .none }
        for (id, observation) in observations where observation == .ended {
            dismissed.remove(id)
        }
        let present = observations.values.compactMap { observation -> DetectedMeeting? in
            if case .present(let meeting) = observation { return meeting }
            return nil
        }.sorted { $0.id < $1.id }
        if recording {
            guard automaticStop else { return .none }
            if recordingMeeting == nil, present.count == 1 { recordingMeeting = present[0] }
            guard let meeting = recordingMeeting else { return .none }
            switch observations[meeting.id] ?? .unknown {
            case .present:
                endedAt = nil
                return .none
            case .unknown:
                endedAt = nil
                return .unavailable
            case .ended:
                if let next = present.first {
                    recordingMeeting = next
                    endedAt = nil
                    return .none
                }
                if endedAt == nil { endedAt = now }
                let remaining = max(0, 30 - Int(now - (endedAt ?? now)))
                return remaining == 0 ? .stop : .countdown(remaining)
            }
        }
        if let meeting = present.first(where: { !dismissed.contains($0.id) }) {
            return .start(meeting)
        }
        return .none
    }

    mutating func startFailed(for meeting: DetectedMeeting) {
        dismissed.insert(meeting.id)
    }

    mutating func setAutomationEnabled(_ enabled: Bool) -> Action {
        if enabled && !automationEnabled { dismissed.removeAll() }
        automationEnabled = enabled
        automaticStop = enabled
        endedAt = nil
        return !enabled && recording && automaticRecording ? .stop : .none
    }

    mutating func recordingStarted(for meeting: DetectedMeeting?, automatic: Bool = false) {
        recording = true
        automaticRecording = automatic
        automaticStop = automationEnabled
        recordingMeeting = meeting
        if let meeting { dismissed.insert(meeting.id) }
        endedAt = nil
    }

    mutating func recordingStopped() {
        if let recordingMeeting { dismissed.insert(recordingMeeting.id) }
        recording = false
        automaticRecording = false
        recordingMeeting = nil
        endedAt = nil
    }

    mutating func keepRecording() {
        automaticStop = false
        recordingMeeting = nil
        endedAt = nil
    }
}

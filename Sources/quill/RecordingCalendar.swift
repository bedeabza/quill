import Foundation

enum RecordingCalendar {
    enum Scope: Hashable, Sendable { case all, month(Date), day(Date) }
    struct Day: Sendable { let date: Date; let count: Int }
    struct Month: Sendable { let date: Date; let days: [Day]; var count: Int { days.reduce(0) { $0 + $1.count } } }
    static func months(_ entries: [RecordingEntry], calendar: Calendar = .autoupdatingCurrent) -> [Month] {
        let grouped = Dictionary(grouping: entries) { calendar.dateInterval(of: .month, for: $0.startedAt)!.start }
        return grouped.keys.sorted(by: >).map { date in
            let days = Dictionary(grouping: grouped[date]!) { calendar.startOfDay(for: $0.startedAt) }
            return Month(date: date, days: days.keys.sorted(by: >).map { Day(date: $0, count: days[$0]!.count) })
        }
    }
    static func includes(_ entry: RecordingEntry, scope: Scope, calendar: Calendar = .autoupdatingCurrent) -> Bool {
        switch scope {
        case .all: return true
        case .day(let date): return calendar.isDate(entry.startedAt, inSameDayAs: date)
        case .month(let date): return calendar.isDate(entry.startedAt, equalTo: date, toGranularity: .month)
        }
    }
    static func timeRange(_ entry: RecordingEntry, calendar: Calendar = .autoupdatingCurrent) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_GB"); formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "HH:mm"
        let start = formatter.string(from: entry.startedAt)
        guard let ended = entry.endedAt else { return start + "–?" }
        let end = formatter.string(from: ended)
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: entry.startedAt), to: calendar.startOfDay(for: ended)).day ?? 0
        let suffix = days > 0 ? " (+\(days)d)" : ""
        return start + "–" + end + suffix
    }
    static func duration(_ seconds: Int?) -> String? {
        guard let seconds, seconds >= 0 else { return nil }
        if seconds < 60 { return "\(seconds)s" }
        let minutes = Int((Double(seconds) / 60).rounded())
        return minutes >= 60 ? String(format: "%dh %02dm", minutes / 60, minutes % 60) : "\(minutes)m"
    }
    static func compactTiming(_ entry: RecordingEntry, calendar: Calendar = .autoupdatingCurrent) -> String {
        timeRange(entry, calendar: calendar) + (duration(entry.duration).map { " · " + $0 } ?? "")
    }
}

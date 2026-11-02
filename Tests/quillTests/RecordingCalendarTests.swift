import Foundation
import XCTest
@testable import quill

final class RecordingCalendarTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(identifier: "Europe/Bucharest")!; return value
    }
    private func entry(_ start: String, end: String? = nil, duration: Int? = nil) -> RecordingEntry {
        .init(directory: URL(fileURLWithPath: "/tmp/" + start), title: "Meeting", startedAt: RecordingsLibrary.parseDate(start)!,
              duration: duration, participants: [], hasTranscript: true, hasNamedTranscript: false, canRegenerate: true,
              endedAt: end.flatMap(RecordingsLibrary.parseDate))
    }
    func testMonthsAndDaysAreNewestFirstAndDoNotCombineDifferentYears() {
        let rows = [entry("2026-11-02T10:00:00Z"), entry("2026-11-02T12:00:00Z"), entry("2026-11-01T10:00:00Z"),
                    entry("2026-10-31T10:00:00Z"), entry("2025-11-02T10:00:00Z")]
        let months = RecordingCalendar.months(rows, calendar: calendar)
        XCTAssertEqual(months.map(\.count), [3, 1, 1])
        XCTAssertEqual(months[0].days.map(\.count), [2, 1])
        XCTAssertEqual(months.map { calendar.component(.year, from: $0.date) }, [2026, 2026, 2025])
        XCTAssertEqual(rows.filter { RecordingCalendar.includes($0, scope: .day(months[0].days[0].date), calendar: calendar) }.count, 2)
        XCTAssertEqual(rows.filter { RecordingCalendar.includes($0, scope: .month(months[0].date), calendar: calendar) }.count, 3)
    }
    func testGroupingUsesLocalDayRatherThanUTCAndHandlesDST() {
        let before = entry("2026-11-01T22:30:00Z"), after = entry("2026-11-02T00:30:00Z")
        XCTAssertEqual(RecordingCalendar.months([before, after], calendar: calendar)[0].days.count, 1)
        let dst = [entry("2026-10-25T00:30:00Z"), entry("2026-10-25T01:30:00Z")]
        XCTAssertEqual(RecordingCalendar.months(dst, calendar: calendar)[0].days.count, 1)
    }
    func testCompactTimingShowsBothEndsAndCrossMidnightExplicitly() {
        let meeting = entry("2026-11-02T10:03:56Z", end: "2026-11-02T11:05:49Z", duration: 3712)
        XCTAssertEqual(RecordingCalendar.compactTiming(meeting, calendar: calendar), "12:03–13:05 · 1h 02m")
        XCTAssertEqual(RecordingCalendar.timeRange(entry("2026-11-02T21:45:00Z", end: "2026-11-02T22:20:00Z"), calendar: calendar), "23:45–00:20 (+1d)")
        XCTAssertEqual(RecordingCalendar.timeRange(entry("2026-11-02T10:03:00Z"), calendar: calendar), "12:03–?")
        XCTAssertEqual(RecordingCalendar.duration(52), "52s")
        XCTAssertNil(RecordingCalendar.duration(-3))
    }
    func testLibraryPrefersRecordedEndThenDurationAndAcceptsFractionalDates() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        for (index, ended) in ["2026-11-02T11:05:49.200Z", "invalid"].enumerated() {
            let dir = root.appendingPathComponent("2026.11.02-1203-\(index)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
            try JSONSerialization.data(withJSONObject: ["files": ["mic": "mic.caf"], "started": "2026-11-02T10:03:56.100Z",
                "ended": ended, "duration_seconds": 60]).write(to: dir.appendingPathComponent("meta.json"))
        }
        let entries = try RecordingsLibrary.entries(in: root)
        XCTAssertTrue(entries.contains { $0.endedAt == RecordingsLibrary.parseDate("2026-11-02T11:05:49.200Z") })
        XCTAssertTrue(entries.contains { $0.endedAt == $0.startedAt.addingTimeInterval(60) })
    }
}

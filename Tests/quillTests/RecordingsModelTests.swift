import XCTest
@testable import quill

@MainActor
final class RecordingsModelTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Vienna")!
        calendar.locale = Locale(identifier: "en_GB")
        return calendar
    }

    private func date(_ text: String) -> Date { RecordingsLibrary.parseDate(text)! }

    private func entry(_ name: String, _ started: String, title: String = "Meeting", participants: [String] = [],
                       transcript: Bool = true, audio: Bool = true) -> RecordingEntry {
        RecordingEntry(directory: URL(fileURLWithPath: "/recordings/" + name, isDirectory: true), title: title,
                       startedAt: date(started), duration: 60, participants: participants, hasTranscript: transcript,
                       hasNamedTranscript: false, canRegenerate: audio)
    }

    func testDaySectionsAreNewestFirstWithRelativeTitles() {
        // 4 November 2026, 23:45 in Vienna (UTC+1).
        let now = date("2026-11-04T22:45:00Z")
        let entries = [
            entry("older-early", "2026-11-02T07:00:00Z"),
            entry("today-mid", "2026-11-04T10:00:00Z"),
            entry("yesterday", "2026-11-03T22:30:00Z"), // 23:30 local on 3 November
            entry("older-late", "2026-11-02T15:00:00Z"),
            entry("today-first", "2026-11-03T23:30:00Z"), // 00:30 local on 4 November
            entry("today-late", "2026-11-04T22:30:00Z"),
        ]
        let sections = RecordingsModel.sections(entries, query: "", now: now, calendar: calendar)
        XCTAssertEqual(sections.map(\.title), ["Today", "Yesterday", "Monday 2 November"])
        XCTAssertEqual(sections.map { $0.entries.map(\.directory.lastPathComponent) },
                       [["today-late", "today-mid", "today-first"], ["yesterday"], ["older-late", "older-early"]])
        XCTAssertEqual(sections[0].day, calendar.startOfDay(for: now))
    }

    func testSearchMatchesParticipantAndFolderName() {
        let entries = [
            entry("2026.11.02-1000", "2026-11-02T09:00:00Z", title: "Weekly sync", participants: ["Alice Smith"]),
            entry("2026.11.03-1400", "2026-11-03T13:00:00Z", title: "Planning", participants: ["Bob"]),
        ]
        let now = date("2026-11-04T11:00:00Z")
        func names(_ query: String) -> [String] {
            RecordingsModel.sections(entries, query: query, now: now, calendar: calendar).flatMap(\.entries).map(\.directory.lastPathComponent)
        }
        XCTAssertEqual(names("alice"), ["2026.11.02-1000"])
        XCTAssertEqual(names("  11.03 "), ["2026.11.03-1400"])
        XCTAssertEqual(names("planning"), ["2026.11.03-1400"])
        XCTAssertEqual(names(""), ["2026.11.03-1400", "2026.11.02-1000"])
        XCTAssertTrue(names("carol").isEmpty)
    }

    func testStatusForEveryCase() {
        let ready = entry("ready", "2026-11-02T09:00:00Z")
        let pending = entry("pending", "2026-11-02T09:00:00Z", transcript: false)
        let unfinished = entry("unfinished", "2026-11-02T09:00:00Z", transcript: false, audio: false)
        XCTAssertEqual(RecordingsModel.status(ready, nil), .ready)
        XCTAssertEqual(RecordingsModel.status(pending, nil), .notTranscribed)
        XCTAssertEqual(RecordingsModel.status(unfinished, nil), .unfinished)
        XCTAssertEqual(RecordingsModel.status(ready, .queued), .queued)
        XCTAssertEqual(RecordingsModel.status(ready, .processing), .transcribing)
        XCTAssertEqual(RecordingsModel.status(ready, .failed("No key")), .failed("No key"))
    }

    func testQueuedMessageNamesTheProcessingRecording() {
        let queued = entry("2026.11.03-1400", "2026-11-03T13:00:00Z")
        let running = URL(fileURLWithPath: "/recordings/2026.11.02-1000", isDirectory: true)
        XCTAssertEqual(RecordingsModel.message(queued, activity: .queued, allActivity: [queued.directory: .queued, running: .processing]),
                       "Queued — waiting for 2026.11.02-1000 to finish. Recordings are processed one at a time.")
        XCTAssertEqual(RecordingsModel.message(queued, activity: .processing, allActivity: [queued.directory: .processing]),
                       "Transcribing… You can browse other recordings while this runs.")
        XCTAssertNil(RecordingsModel.message(queued, activity: nil, allActivity: [:]))
    }
}

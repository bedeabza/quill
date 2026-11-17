import XCTest
@testable import quill

final class RecordingHTMLExportTests: XCTestCase {
    private func entry(_ title: String = "Buget și lansare", directory: URL = URL(fileURLWithPath: "/fixture/recording")) -> RecordingEntry {
        .init(directory: directory, title: title, startedAt: Date(timeIntervalSince1970: 1_794_218_400), duration: 120,
              participants: ["Ana & Bogdan"], hasTranscript: true, hasNamedTranscript: false, canRegenerate: false,
              endedAt: Date(timeIntervalSince1970: 1_794_218_520))
    }

    func testExportEscapesContentAndIncludesDisplayedNamesTitleAndTimes() throws {
        let document = try RecordingHTMLExport.make(entry: entry("Buget <2027> & \"lansare\""), preview: .turns([
            .init(id: 0, start: 65, speaker: "Saved name", text: "Ședință: <script>alert('x')</script>\nA & B", speakerID: "meeting_1"),
            .init(id: 1, start: 130, speaker: "Speaker 2", text: "A doua intervenție.", speakerID: "meeting_2"),
        ]), names: ["meeting_1": "Andrei <Popescu>"])
        XCTAssertTrue(document.html.contains("Buget &lt;2027&gt; &amp; &quot;lansare&quot;"))
        XCTAssertTrue(document.html.contains("Andrei &lt;Popescu&gt;"))
        XCTAssertFalse(document.html.contains("Saved name"))
        XCTAssertTrue(document.html.contains("Ana &amp; Bogdan"))
        XCTAssertTrue(document.html.contains("00:01:05"))
        XCTAssertTrue(document.html.contains("Ședință: &lt;script&gt;alert(&#39;x&#39;)&lt;/script&gt;"))
        XCTAssertFalse(document.html.contains("<script>"))
        XCTAssertFalse(document.html.contains("/fixture/recording"))
        XCTAssertTrue(document.html.contains("href=\"#turn-0\""))
        XCTAssertTrue(document.html.contains("charset=\"utf-8\""))
    }

    func testSameNameVoicesRemainDistinctAndUnknownOverrideMatchesThePreview() throws {
        let document = try RecordingHTMLExport.make(entry: entry(), preview: .turns([
            .init(id: 0, start: 0, speaker: "Alex", text: "First voice.", speakerID: "meeting_1"),
            .init(id: 1, start: 10, speaker: "Alex", text: "Second voice.", speakerID: "meeting_2"),
        ]), names: ["meeting_1": ""])
        XCTAssertTrue(document.html.contains("voice-link voice-0\" href=\"#turn-0\">Speaker 1</a>"))
        XCTAssertTrue(document.html.contains("voice-link voice-1\" href=\"#turn-1\">Alex</a>"))
        XCTAssertTrue(document.html.contains("Second voice."))
    }

    func testMarkdownFallbackIsTextAndMissingTranscriptsCannotExport() throws {
        let document = try RecordingHTMLExport.make(entry: entry(), preview: .text("# Ședință\n<img src=x onerror=alert(1)>"))
        XCTAssertTrue(document.html.contains("&lt;img src=x onerror=alert(1)&gt;"))
        XCTAssertTrue(document.html.contains("# Ședință"))
        XCTAssertFalse(document.html.contains("<img"))
        XCTAssertThrowsError(try RecordingHTMLExport.make(entry: entry(), preview: .empty("Unavailable")))
        XCTAssertThrowsError(try RecordingHTMLExport.make(entry: entry(), preview: .turns([])))
        XCTAssertThrowsError(try RecordingHTMLExport.make(entry: entry(), preview: .text(" \n")))
    }

    func testFilenameIsPortableAndWritingCannotReplaceRecordingJSON() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("quill-html-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let document = try RecordingHTMLExport.make(entry: entry("../Buget: ținte / lansare?\n2027"), preview: .text("Conținut actualizat."))
        XCTAssertFalse(document.suggestedFilename.contains("/"))
        XCTAssertFalse(document.suggestedFilename.contains(":"))
        XCTAssertFalse(document.suggestedFilename.contains("\n"))
        XCTAssertTrue(document.suggestedFilename.hasSuffix(".html"))
        XCTAssertTrue(RecordingHTMLExport.filename(for: entry(String(repeating: "🙂", count: 150))).utf8.count < 255)
        let destination = root.appendingPathComponent(document.suggestedFilename)
        try document.write(to: destination)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), document.html)
        let original = root.appendingPathComponent("transcript.json")
        try Data("original transcript".utf8).write(to: original)
        XCTAssertThrowsError(try document.write(to: original))
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "original transcript")
    }

    @MainActor
    func testModelExportsNamedCopyAndDraftsWithoutLeakingThemToAnotherRecording() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("quill-html-model-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        func recording(_ folder: String, started: String, name: String, text: String) throws -> URL {
            let directory = root.appendingPathComponent(folder)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            try JSONSerialization.data(withJSONObject: ["started": started, "files": [:]])
                .write(to: directory.appendingPathComponent("meta.json"))
            var transcript = Transcript(engine: "elevenlabs", model: "scribe_v2", created_at: "fixture", segments: [
                .init(speaker: "meeting_1", start_ms: 0, end_ms: 1000, text: "Original wording.", source: "meeting")], variant: "elevenlabs_original")
            try transcript.write(to: directory)
            transcript.variant = "elevenlabs_named"
            transcript.segments[0].speaker_name = name
            transcript.segments[0].text = text
            try transcript.write(to: directory, basename: "transcript-named")
            return RecordingsLibrary.canonicalDirectory(directory)
        }
        let first = try recording("2026.11.09-1000", started: "2026-11-09T08:00:00Z", name: "Alice", text: "Corrected discussion text.")
        let second = try recording("2026.11.08-1000", started: "2026-11-08T08:00:00Z", name: "Bob", text: "Other discussion text.")
        func originals() throws -> [Data] {
            try [first, second].flatMap { directory in
                try ["transcript.json", "transcript.md", "transcript-named.json", "transcript-named.md"].map {
                    try Data(contentsOf: directory.appendingPathComponent($0))
                }
            }
        }
        let before = try originals()
        let model = RecordingsModel(root: root, transcription: TranscriptionCoordinator(),
            titles: RecordingTitleCoordinator(mode: { .off }, generate: { _, _, _ in }))
        model.refresh()
        for _ in 0..<100 { if model.transcript != nil { break }; try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.selection, first)
        model.setSpeakerName("Andrei", for: "meeting_1")
        let document = try await model.htmlExport(for: XCTUnwrap(model.selectedEntry))
        XCTAssertTrue(document.html.contains("Corrected discussion text."))
        XCTAssertFalse(document.html.contains("Original wording."))
        XCTAssertTrue(document.html.contains("Andrei"))
        let otherEntry = try XCTUnwrap(model.entries.first { $0.directory == second })
        let other = try await model.htmlExport(for: otherEntry)
        XCTAssertTrue(other.html.contains("Bob"))
        XCTAssertFalse(other.html.contains("Andrei"))
        model.discardSpeakerNameChanges()
        XCTAssertTrue(document.html.contains("Andrei"), "the export snapshot is immutable")
        XCTAssertEqual(try originals(), before)
    }
}

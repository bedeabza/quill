import XCTest
@testable import quill

final class SpeakerNavigationTests: XCTestCase {
    func testEachVoiceCyclesIndependentlyAndIgnoresDisplayNames() {
        let turns = [
            TranscriptTurn(id: 0, start: 0, end: 5, speaker: "Alex", text: "One", speakerID: "meeting_1"),
            TranscriptTurn(id: 1, start: 10, end: 15, speaker: "Alex", text: "Two", speakerID: "meeting_2"),
            TranscriptTurn(id: 2, start: 20, end: 25, speaker: "Alex", text: "Three", speakerID: "meeting_1"),
            TranscriptTurn(id: 3, start: 30, end: 35, speaker: "Alex", text: "Four", speakerID: "meeting_2"),
        ]
        var navigation = SpeakerTurnNavigation()
        XCTAssertEqual(navigation.next("meeting_1", in: turns)?.id, 0)
        XCTAssertEqual(navigation.next("meeting_2", in: turns)?.id, 1)
        XCTAssertEqual(navigation.next("meeting_1", in: turns)?.id, 2)
        XCTAssertEqual(navigation.next("meeting_1", in: turns)?.id, 0)
        XCTAssertEqual(navigation.next("meeting_2", in: turns)?.id, 3)
        XCTAssertNil(navigation.next("missing", in: turns))
        XCTAssertEqual(navigation.next("meeting_1", in: Array(turns.suffix(2)))?.id, 2)
    }

    @MainActor
    func testCustomNamePreviewsImmediatelyCancelsAndSavesWithoutChangingOriginal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("quill-navigation-" + UUID().uuidString)
        let directory = root.appendingPathComponent("2026.11.09-1000")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(#"{"started":"2026-11-09T08:00:00Z","duration_seconds":100,"files":{},"microphone_gaps":[{"start":40,"end":100}]}"#.utf8)
            .write(to: directory.appendingPathComponent("meta.json"))
        let original = Transcript(engine: "elevenlabs", model: "scribe_v2", created_at: "fixture", segments: [
            .init(speaker: "meeting_1", start_ms: 0, end_ms: 1000, text: "First.", source: "meeting", provider_speaker_id: "speaker_0"),
            .init(speaker: "meeting_2", start_ms: 1000, end_ms: 2000, text: "Second.", source: "meeting", provider_speaker_id: "speaker_1"),
            .init(speaker: "meeting_1", start_ms: 2000, end_ms: 3000, text: "Third.", source: "meeting", provider_speaker_id: "speaker_0"),
        ], variant: "elevenlabs_original")
        try original.write(to: directory)
        let reports = ["meeting_1", "meeting_2"].map {
            ElevenLabsTranscripts.SpeakerEvidenceReport(speaker: $0, provider_speaker_id: $0, candidate_name: nil,
                agreement: 0, observed_seconds: 0, speech_seconds: 2, observed_fraction: 0, ambiguous_seconds: 0, accepted: false)
        }
        try JSONEncoder().encode(ElevenLabsTranscripts.MappingReport(accepted: false, speakers: reports))
            .write(to: directory.appendingPathComponent("speaker-mapping.json"))
        let originalURL = directory.appendingPathComponent("transcript.json"), before = try Data(contentsOf: originalURL)
        let model = RecordingsModel(root: root, transcription: TranscriptionCoordinator(),
                                   titles: RecordingTitleCoordinator(mode: { .off }, generate: { _, _, _ in }), uploadCorrection: { _ in })
        model.refresh()
        for _ in 0..<200 {
            if model.speakerNames != nil, model.transcript != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard case .turns(let turns) = model.transcript else { return XCTFail("No transcript loaded") }
        XCTAssertEqual(model.speakerNames?.rows.count, 2)
        let microphoneNotice = "Microphone stopped at 0:40. Your voice after that wasn’t recorded."
        XCTAssertEqual(model.microphoneNotice, microphoneNotice)
        model.setSpeakerName("Andrei Popescu", for: "meeting_1")
        XCTAssertEqual(model.displayName(for: turns[0]), "Andrei Popescu")
        XCTAssertEqual(model.displayName(for: turns[2]), "Andrei Popescu")
        XCTAssertEqual(model.displayName(for: turns[1]), "Speaker 2")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("transcript-named.json").path))
        model.nextSpeakerTurn("meeting_1")
        XCTAssertEqual(model.speakerTurnTarget, 0)
        model.nextSpeakerTurn("meeting_1")
        XCTAssertEqual(model.speakerTurnTarget, 2)
        model.setSpeakerName("Ana", for: "meeting_1")
        model.nextSpeakerTurn("meeting_1")
        XCTAssertEqual(model.speakerTurnTarget, 0, "renaming preserves the voice's navigation cursor")
        model.discardSpeakerNameChanges()
        XCTAssertEqual(model.displayName(for: turns[0]), "Speaker 1")
        model.setSpeakerName("Andrei Popescu", for: "meeting_1")
        model.setSpeakerName("Bianca", for: "meeting_2")
        model.speakerNameEditorCollapsed = true
        XCTAssertFalse(model.showsSpeakerNames)
        XCTAssertEqual(model.displayName(for: turns[0]), "Andrei Popescu")
        model.openSpeakerNameEditor()
        XCTAssertTrue(model.showsSpeakerNames)
        model.setSpeakerName(String(repeating: "x", count: 101), for: "meeting_2")
        model.applySpeakerNameDrafts()
        XCTAssertNotNil(model.speakerNamesError)
        XCTAssertFalse(model.isApplyingSpeakerNames)
        model.setSpeakerName("Bianca", for: "meeting_2")
        // Force the preview reload shared by microphone notices and draft names.
        try Data("Updated Markdown preview".utf8).write(to: directory.appendingPathComponent("transcript.md"))
        model.refresh()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(model.displayName(for: turns[0]), "Andrei Popescu", "polling must keep edits")
        XCTAssertEqual(model.microphoneNotice, microphoneNotice)
        model.applySpeakerNameDrafts()
        for _ in 0..<200 {
            if !model.isApplyingSpeakerNames, model.speakerNames?.complete == true { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let named = try JSONDecoder().decode(Transcript.self, from: Data(contentsOf: directory.appendingPathComponent("transcript-named.json")))
        XCTAssertEqual(named.segments.map(\.speaker_name), ["Andrei Popescu", "Bianca", "Andrei Popescu"])
        XCTAssertEqual(named.segments.map(\.attribution), ["manual", "manual", "manual"])
        XCTAssertEqual(try Data(contentsOf: originalURL), before)
        XCTAssertTrue(model.speakerNameDrafts.isEmpty)
        XCTAssertEqual(model.microphoneNotice, microphoneNotice)
        model.nextSpeakerTurn("meeting_2")
        XCTAssertEqual(model.speakerTurnTarget, 1)
        model.selection = nil
        XCTAssertNil(model.speakerTurnTarget)
        XCTAssertNil(model.microphoneNotice)
    }
}

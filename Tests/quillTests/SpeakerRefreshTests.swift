import ArgumentParser
import XCTest
@testable import quill

final class SpeakerRefreshTests: XCTestCase, @unchecked Sendable {
    private func fixture() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("quill-speaker-refresh-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let audio = directory.appendingPathComponent("system.caf")
        try Data("synthetic cached audio".utf8).write(to: audio)
        let response = ElevenLabsEngine.Response(language_code: "eng", language_probability: 1, text: "Hello.",
            words: [.init(text: "Hello.", start: 9, end: 9.5, type: "word")])
        let cache = ElevenLabsEngine.Cache(version: 1, model: "scribe_v2", audioSHA256: try ElevenLabsEngine.fingerprint(audio), response: response)
        try JSONEncoder().encode(cache).write(to: directory.appendingPathComponent("elevenlabs-system.caf.json"))
        let transcript = Transcript(engine: "elevenlabs", model: "scribe_v2", created_at: "fixture", segments: [
            .init(speaker: "system_1", start_ms: 9250, end_ms: 9750, text: "Hello.", source: "system"),
            .init(speaker: "me", start_ms: 20000, end_ms: 21000, text: "Local words.", source: "mic", speaker_name: "Local person")], schema_version: 2)
        try transcript.write(to: directory)
        let analysis = SpeakerAnalysis(turns: [.init(speaker_id: "system_1", start: 0.25, end: 12.25),
                                               .init(speaker_id: "system_1", start: 20.25, end: 32.25)], names: [:])
        try JSONEncoder().encode(analysis).write(to: directory.appendingPathComponent("speaker-analysis.json"))
        try Data(#"{"files":{"system":"system.caf"},"audio_started_at":1000,"start_offset_ms":{"system":250}}"#.utf8)
            .write(to: directory.appendingPathComponent("meta.json"))
        var observations: [SpeakerObservation] = []
        for base in [1.0, 21.0] {
            for step in 0...28 {
                observations.append(SpeakerObservation(observed_at: 1000.25 + base + Double(step) * 0.25,
                    meeting_id: "fixture", names: ["Alice"], source: "meeting_tile"))
            }
        }
        let lines = try observations.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }.joined(separator: "\n")
        try Data(lines.utf8).write(to: directory.appendingPathComponent("speaker-observations.jsonl"))
        return directory
    }

    func testOfflineRefreshBacksUpAndPreservesWordsOffsetsAndLocalSpeaker() async throws {
        let directory = try fixture()
        let url = directory.appendingPathComponent("transcript.json")
        let original = try Data(contentsOf: url)
        let command = try RefreshSpeakers.parse([directory.path])
        try await command.refresh()
        let transcript = try JSONDecoder().decode(Transcript.self, from: Data(contentsOf: url))
        XCTAssertEqual(transcript.segments.map(\.text), ["Hello.", "Local words."])
        XCTAssertEqual(transcript.segments.map(\.start_ms), [9250, 20000])
        XCTAssertEqual(transcript.segments.map(\.end_ms), [9750, 21000])
        XCTAssertEqual(transcript.segments.map(\.speaker_name), ["Alice", "Local person"])
        let backups = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("speaker-refresh-backup-") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: backups[0].appendingPathComponent("transcript.json")), original)
        let analysis = try JSONDecoder().decode(SpeakerAnalysis.self, from: Data(contentsOf: directory.appendingPathComponent("speaker-analysis.json")))
        XCTAssertEqual(analysis.voice_identities?["system_1"]?.name, "Alice")
    }

    func testPreviewLeavesRecordingUnchanged() async throws {
        let directory = try fixture(), preview = directory.appendingPathComponent("preview")
        let original = try Data(contentsOf: directory.appendingPathComponent("transcript.json"))
        let command = try RefreshSpeakers.parse([directory.path, "--output", preview.path])
        try await command.refresh()
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("transcript.json")), original)
        XCTAssertTrue(FileManager.default.fileExists(atPath: preview.appendingPathComponent("transcript.json").path))
    }

    func testEditedTextAndManualLabelsAreNotOverwritten() async throws {
        for manual in [false, true] {
            let directory = try fixture(), url = directory.appendingPathComponent("transcript.json")
            var transcript = try JSONDecoder().decode(Transcript.self, from: Data(contentsOf: url))
            if manual { transcript.segments[0].attribution = "manual"; transcript.segments[0].speaker_name = "Bob" }
            else { transcript.segments[0].text = "Edited words." }
            try transcript.write(to: directory)
            let original = try Data(contentsOf: url)
            do { try await RefreshSpeakers.parse([directory.path]).refresh(); XCTFail("Edited data should be protected") }
            catch { XCTAssertTrue(error is ValidationError) }
            XCTAssertEqual(try Data(contentsOf: url), original)
        }
    }

    func testChangedAudioInvalidatesCachedWordTimes() async throws {
        let directory = try fixture(), url = directory.appendingPathComponent("transcript.json")
        let original = try Data(contentsOf: url)
        try Data("changed audio".utf8).write(to: directory.appendingPathComponent("system.caf"))
        do { try await RefreshSpeakers.parse([directory.path]).refresh(); XCTFail("Mismatched audio should be rejected") }
        catch { XCTAssertTrue(error is ValidationError) }
        XCTAssertEqual(try Data(contentsOf: url), original)
    }
}

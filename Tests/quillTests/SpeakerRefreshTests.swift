import ArgumentParser
import XCTest
@testable import quill

final class SpeakerRefreshTests: XCTestCase, @unchecked Sendable {
    private func fixture() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("quill-speaker-refresh-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        try Data(#"{"files":{"mic":"mic.caf","system":"system.caf"},"audio_started_at":1000,"start_offset_ms":{"system":250},"local_speaker_name":"Local person","meeting_title":"Planning"}"#.utf8)
            .write(to: directory.appendingPathComponent("meta.json"))
        let meta = try SessionMeta.read(from: directory)
        var tracks: [ElevenLabsTranscripts.TrackResult] = []
        for track in meta.tracks {
            let audio = directory.appendingPathComponent(track.file)
            try Data("synthetic cached audio".utf8).write(to: audio)
            let remote = track.source == "system"
            let response = ElevenLabsEngine.Response(language_code: "eng", language_probability: 1,
                text: remote ? "Hello." : "Local words.", words: [.init(text: remote ? "Hello." : "Local words.",
                    start: remote ? 9 : 20, end: remote ? 10 : 21, type: "word", speaker_id: "speaker_0")])
            let cache = ElevenLabsEngine.Cache(version: ElevenLabsEngine.cacheVersion, model: "scribe_v2",
                audioSHA256: try ElevenLabsEngine.fingerprint(audio), response: response)
            try JSONEncoder().encode(cache).write(to: directory.appendingPathComponent("elevenlabs-\(track.file).json"))
            tracks.append(.init(track: track, segments: try ElevenLabsEngine.segments(response)))
        }
        let observations = (0..<4).map { index in
            SpeakerObservation(observed_at: 1000.25 + 9.125 + Double(index) * 0.25,
                meeting_id: "fixture", names: ["Alice"], source: "meeting_tile")
        }
        let lines = try observations.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }.joined(separator: "\n")
        try Data(lines.utf8).write(to: directory.appendingPathComponent("speaker-observations.jsonl"))
        try ElevenLabsTranscripts.build(meta: meta, tracks: tracks, roster: ParticipantRoster(audio_started_at: 1000), observations: []).write(to: directory)
        return directory
    }

    func testOfflineRefreshPreservesOriginalAndCreatesSeparateNamedVariant() async throws {
        let directory = try fixture(), url = directory.appendingPathComponent("transcript.json")
        let original = try Data(contentsOf: url)
        try await RefreshSpeakers.parse([directory.path]).refresh()
        XCTAssertEqual(try Data(contentsOf: url), original)
        let named = try JSONDecoder().decode(Transcript.self, from: Data(contentsOf: directory.appendingPathComponent("transcript-named.json")))
        XCTAssertEqual(named.segments.map(\.text), ["Hello.", "Local words."])
        XCTAssertEqual(named.segments.map(\.start_ms), [9250, 20000])
        XCTAssertEqual(named.segments.map(\.end_ms), [10250, 21000])
        XCTAssertEqual(named.segments.compactMap(\.speaker_name), ["Alice", "Local person"])
        XCTAssertEqual(named.meeting_title, "Planning")
        let backups = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix("speaker-refresh-backup-") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(backups[0]).appendingPathComponent("transcript.json")), original)
    }

    func testPreviewLeavesRecordingUnchanged() async throws {
        let directory = try fixture(), preview = directory.appendingPathComponent("preview")
        let original = try Data(contentsOf: directory.appendingPathComponent("transcript.json"))
        try await RefreshSpeakers.parse([directory.path, "--output", preview.path]).refresh()
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("transcript.json")), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("transcript-named.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: preview.appendingPathComponent("transcript-named.json").path))
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

    func testChangedAudioInvalidatesCachedDiarization() async throws {
        let directory = try fixture(), url = directory.appendingPathComponent("transcript.json")
        let original = try Data(contentsOf: url)
        try Data("changed audio".utf8).write(to: directory.appendingPathComponent("system.caf"))
        do { try await RefreshSpeakers.parse([directory.path]).refresh(); XCTFail("Mismatched audio should be rejected") }
        catch { XCTAssertTrue(error is ValidationError) }
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testOldUndiarizedCacheAndForcedLocalSeparationAreRejected() async throws {
        let directory = try fixture()
        do { try await RefreshSpeakers.parse([directory.path, "--remote-speakers", "2"]).refresh(); XCTFail("Must not run local models") }
        catch { XCTAssertTrue(error is ValidationError) }
        let file = directory.appendingPathComponent("elevenlabs-system.caf.json")
        let saved = try JSONDecoder().decode(ElevenLabsEngine.Cache.self, from: Data(contentsOf: file))
        let old = ElevenLabsEngine.Cache(version: 1, model: saved.model, audioSHA256: saved.audioSHA256, response: saved.response)
        try JSONEncoder().encode(old).write(to: file)
        do { try await RefreshSpeakers.parse([directory.path]).refresh(); XCTFail("Version 1 did not request diarization") }
        catch { XCTAssertTrue(error is ValidationError) }
    }

    func testMissingTimelineRemovesStaleNamedVariant() async throws {
        let directory = try fixture()
        try await RefreshSpeakers.parse([directory.path]).refresh()
        try FileManager.default.removeItem(at: directory.appendingPathComponent("speaker-observations.jsonl"))
        try await RefreshSpeakers.parse([directory.path]).refresh()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("transcript-named.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("transcript.json").path))
    }
}

import Foundation
import ArgumentParser
import XCTest
@testable import quill

private actor MeetingUploadStub: TranscriptionEngine {
    nonisolated let name = "elevenlabs"
    nonisolated let model = "scribe_v2"
    private(set) var calls: [String] = []
    func prepare() async throws {}
    func release() async {}
    func transcribe(_ audio: URL) async throws -> [TranscriptSegment] {
        _ = try AudioTestSupport.read(audio)
        calls.append(audio.lastPathComponent)
        return [.init(start: 0.1, end: 0.4, text: "Local.", words: [.init(start: 0.1, end: 0.4, text: "Local.")], speakerID: "speaker_0"),
                .init(start: 0.5, end: 0.9, text: "Remote.", words: [.init(start: 0.5, end: 0.9, text: "Remote.")], speakerID: "speaker_1")]
    }
}

final class MeetingAudioTests: XCTestCase, @unchecked Sendable {
    private func directory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("quill-meeting-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }
    private func session(_ dir: URL) throws -> SessionMeta {
        try AudioTestSupport.write(dir.appendingPathComponent("mic.caf"))
        try AudioTestSupport.write(dir.appendingPathComponent("system.caf"))
        try Data(#"{"files":{"mic":"mic.caf","system":"system.caf"},"start_offset_ms":{"mic":100,"system":0},"audio_started_at":1000,"meeting_title":"Planning","local_speaker_name":"Local"}"#.utf8)
            .write(to: dir.appendingPathComponent("meta.json"))
        return try SessionMeta.read(from: dir)
    }
    private func input(_ source: String, offset: Int = 0) -> MeetingAudio.Input {
        .init(file: source + ".wav", source: source, offset_ms: offset, sha256: "synthetic")
    }

    func testDelayedPlaybackIsReducedAndSimultaneousLocalAudioIsPreserved() throws {
        let dir = try directory(), rate = MeetingAudio.sampleRate, count = rate * 18, delay = rate / 20
        var seed: UInt64 = 123, otherSeed: UInt64 = 456, a = 0.0, b = 0.0
        var playback = [Int16](repeating: 0, count: count), local = playback, mic = playback
        for i in 0..<count {
            seed = seed &* 6364136223846793005 &+ 1
            otherSeed = otherSeed &* 6364136223846793005 &+ 1
            a = 0.6 * a + 0.4 * (Double(Int32(truncatingIfNeeded: seed >> 32)) / Double(Int32.max))
            b = 0.4 * b + 0.6 * (Double(Int32(truncatingIfNeeded: otherSeed >> 32)) / Double(Int32.max))
            playback[i] = Int16(a * 14000)
            local[i] = i > rate * 10 ? Int16(b * 7000) : 0
            let echo = i >= delay ? Double(playback[i - delay]) * 0.6 : 0
            let reflection = i >= delay + 80 ? Double(playback[i - delay - 80]) * 0.15 : 0
            mic[i] = Int16(clamping: Int(echo + reflection + Double(local[i])))
        }
        let micURL = dir.appendingPathComponent("mic.wav"), systemURL = dir.appendingPathComponent("system.wav")
        try AudioTestSupport.write(micURL, samples: mic); try AudioTestSupport.write(systemURL, samples: playback)
        let out = dir.appendingPathComponent("out.wav")
        let report = try MeetingAudio.mix(inputs: [input("mic"), input("system")], decoded: ["mic": micURL, "system": systemURL], output: out)
        let mixed = try AudioTestSupport.read(out)
        var echoBefore = 0.0, echoAfter = 0.0, localProjection = 0.0, localEnergy = 0.0
        for i in rate * 5..<rate * 9 {
            let cleaned = 2 * Double(mixed[i]) - Double(playback[i])
            echoBefore += Double(mic[i]) * Double(mic[i]); echoAfter += cleaned * cleaned
        }
        for i in rate * 12..<rate * 17 {
            let cleaned = 2 * Double(mixed[i]) - Double(playback[i])
            localProjection += cleaned * Double(local[i]); localEnergy += Double(local[i]) * Double(local[i])
        }
        print("Synthetic delayed echo residual ratio:", echoAfter / echoBefore, "local gain:", localProjection / localEnergy)
        XCTAssertTrue(echoAfter / echoBefore < 0.1)
        XCTAssertTrue(localProjection / localEnergy > 0.7)
        XCTAssertTrue(localProjection / localEnergy < 1.2)
        XCTAssertEqual(mixed.count, count)
        XCTAssertEqual(report.audio_sha256, try ElevenLabsEngine.fingerprint(out))
        XCTAssertTrue(report.cleaned_microphone_energy < report.microphone_energy)
    }

    func testSingleTrackOffsetIsExactAndOriginalSamplesAreUnchanged() throws {
        let dir = try directory(), original = dir.appendingPathComponent("mic.wav"), out = dir.appendingPathComponent("out.wav")
        let samples: [Int16] = [1500, -2500, 32000, -32000] + [Int16](repeating: 700, count: 999)
        try AudioTestSupport.write(original, samples: samples)
        let hash = try ElevenLabsEngine.fingerprint(original)
        let manifest = try MeetingAudio.mix(inputs: [input("mic", offset: 100)], decoded: ["mic": original], output: out)
        let mixed = try AudioTestSupport.read(out)
        XCTAssertEqual(Array(mixed.prefix(1600)), [Int16](repeating: 0, count: 1600))
        XCTAssertEqual(Array(mixed.dropFirst(1600)), samples)
        XCTAssertEqual(manifest.frames, 2603)
        XCTAssertEqual(try ElevenLabsEngine.fingerprint(original), hash)
    }

    func testSilenceAndUnequalTrackEndsKeepFullMeetingDuration() throws {
        let dir = try directory(), mic = dir.appendingPathComponent("mic.wav"), system = dir.appendingPathComponent("system.wav")
        try AudioTestSupport.write(mic, samples: [Int16](repeating: 0, count: 1003))
        try AudioTestSupport.write(system, samples: [Int16](repeating: 0, count: 1801))
        let out = dir.appendingPathComponent("out.wav")
        let manifest = try MeetingAudio.mix(inputs: [input("mic", offset: 200), input("system")], decoded: ["mic": mic, "system": system], output: out)
        XCTAssertEqual(manifest.frames, 4203)
        XCTAssertTrue(try AudioTestSupport.read(out).allSatisfy { $0 == 0 })
        XCTAssertTrue(manifest.local_windows.isEmpty && manifest.remote_windows.isEmpty)
    }

    func testEchoFilterCannotCreateAudioOutsideMicrophoneCapture() throws {
        let dir = try directory(), mic = dir.appendingPathComponent("mic.wav"), system = dir.appendingPathComponent("system.wav")
        let playback = (0..<64000).map { Int16(sin(Double($0) * 0.09) * 8000) }
        try AudioTestSupport.write(mic, samples: Array(playback[1600..<48000]).map { $0 / 2 })
        try AudioTestSupport.write(system, samples: playback)
        let out = dir.appendingPathComponent("out.wav")
        _ = try MeetingAudio.mix(inputs: [input("mic", offset: 100), input("system")], decoded: ["mic": mic, "system": system], output: out)
        let mixed = try AudioTestSupport.read(out)
        XCTAssertEqual(Array(mixed.prefix(1600)), Array(playback.prefix(1600)).map { $0 / 2 })
        XCTAssertEqual(Array(mixed[48000...]), Array(playback[48000...]).map { $0 / 2 })
    }

    func testPreparationCacheTracksOffsetsOriginalHashesAndPreparedFileIntegrity() async throws {
        let dir = try directory(), meta = try session(dir)
        let original = try ElevenLabsEngine.fingerprint(dir.appendingPathComponent("mic.caf"))
        let first = try await MeetingAudio.prepare(in: dir, meta: meta)
        let date = try first.audio.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        _ = try await MeetingAudio.prepare(in: dir, meta: meta)
        XCTAssertEqual(try first.audio.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, date)
        XCTAssertEqual(first.manifest.frames, 17600)
        let changed = SessionMeta(tracks: [.init(file: "mic.caf", speaker: "me", offsetMs: 200), meta.tracks[1]],
            audioStartedAt: 1000, localSpeakerName: "Local", sharedMicrophone: false)
        XCTAssertNil(try MeetingAudio.cached(in: dir, meta: changed))
        let second = try await MeetingAudio.prepare(in: dir, meta: changed)
        XCTAssertEqual(second.manifest.frames, 19200)
        try Data("damaged".utf8).write(to: second.audio)
        XCTAssertNil(try MeetingAudio.cached(in: dir, meta: changed))
        _ = try await MeetingAudio.prepare(in: dir, meta: changed)
        XCTAssertTrue(try MeetingAudio.cached(in: dir, meta: changed) != nil)
        XCTAssertEqual(try ElevenLabsEngine.fingerprint(dir.appendingPathComponent("mic.caf")), original)
        try FileManager.default.removeItem(at: dir.appendingPathComponent("system.caf"))
        do { _ = try await MeetingAudio.prepare(in: dir, meta: changed); XCTFail("Missing source must fail even with a prepared cache") }
        catch {}
    }

    func testCoordinatorMakesOneCombinedCallAndKeepsLegacyResponses() async throws {
        let dir = try directory(); _ = try session(dir)
        let engine = MeetingUploadStub()
        let old = Data("old per-track response".utf8)
        try old.write(to: dir.appendingPathComponent("elevenlabs-mic.caf.json"))
        let coordinator = TranscriptionCoordinator { _, _ in engine }
        try await coordinator.transcribe(dir, engineOverride: .elevenLabs)
        let calls = await engine.calls
        XCTAssertEqual(calls, [MeetingAudio.filename])
        let transcript = try JSONDecoder().decode(Transcript.self, from: Data(contentsOf: dir.appendingPathComponent("transcript.json")))
        XCTAssertEqual(transcript.segments.map(\.speaker), ["meeting_1", "meeting_2"])
        XCTAssertEqual(transcript.segments.map(\.provider_speaker_id), ["speaker_0", "speaker_1"])
        XCTAssertTrue(transcript.segments.allSatisfy { $0.source == "meeting" && $0.speaker_name == nil })
        XCTAssertEqual(transcript.meeting_title, "Planning")
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("elevenlabs-mic.caf.json")), old)
    }

    func testRegenerationRestoresPreparedAudioAndManifestAndFreshDeletesOnlyCombinedResponse() throws {
        let dir = try directory(); _ = try session(dir)
        let old = Data("old".utf8)
        for name in [MeetingAudio.filename, MeetingAudio.manifestName, MeetingAudio.cacheName, "elevenlabs-mic.caf.json"] {
            try old.write(to: dir.appendingPathComponent(name))
        }
        let replacement = try RecordingRegeneration(directory: dir, freshCloud: true)
        defer { replacement.unlock() }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent(MeetingAudio.cacheName).path))
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("elevenlabs-mic.caf.json")), old)
        try Data("new".utf8).write(to: dir.appendingPathComponent(MeetingAudio.filename))
        try Data("new".utf8).write(to: dir.appendingPathComponent(MeetingAudio.manifestName))
        try replacement.restore()
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent(MeetingAudio.filename)), old)
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent(MeetingAudio.manifestName)), old)
    }

    func testCombinedMappingRequiresEveryVoiceAndActualLocalEvidence() {
        let track = SessionMeta.Track(file: MeetingAudio.filename, speaker: "meeting", offsetMs: 0)
        let manifest = MeetingAudio.Manifest(version: 1, algorithm: "fixture", sample_rate: 16000, inputs: [], audio_sha256: "fixture", frames: 80000,
            microphone_energy: 0, cleaned_microphone_energy: 0, system_energy: 0,
            local_windows: [.init(start: 0, end: 2)], remote_windows: [.init(start: 3, end: 5)])
        let segments: [TranscriptSegment] = [.init(start: 0, end: 2, text: "Local", speakerID: "speaker_0"), .init(start: 3, end: 5, text: "Remote", speakerID: "speaker_1")]
        let local = stride(from: 0.125, to: 2, by: 0.25).map { SpeakerObservation(observed_at: 1000 + $0, meeting_id: "test", names: [], source: "meeting_tile", local_names: ["Local"]) }
        let remote = stride(from: 3.125, to: 5, by: 0.25).map { SpeakerObservation(observed_at: 1000 + $0, meeting_id: "test", names: ["Alice"], source: "meeting_tile") }
        func build(shared: Bool, samples: [SpeakerObservation]) -> ElevenLabsTranscripts.Output {
            ElevenLabsTranscripts.build(meta: .init(tracks: [track], audioStartedAt: 1000, localSpeakerName: "Local", sharedMicrophone: shared),
                tracks: [.init(track: track, segments: segments, meetingAudio: manifest)], roster: .init(audio_started_at: 1000), observations: samples)
        }
        XCTAssertNil(build(shared: false, samples: remote).named)
        let complete = build(shared: false, samples: local + remote)
        XCTAssertEqual(complete.named?.segments.compactMap(\.speaker_name), ["Local", "Alice"])
        XCTAssertTrue(complete.original.segments.allSatisfy { $0.speaker_name == nil })
        XCTAssertNil(build(shared: true, samples: local + remote).named)
        // A stale remote indicator during microphone-only speech cannot name it.
        let wrong = local.map { SpeakerObservation(observed_at: $0.observed_at, meeting_id: "test", names: ["Alice"], source: "meeting_tile") }
        XCTAssertNil(build(shared: false, samples: wrong + remote).named)
    }

    func testMeetSelfLabelNeedsAnActualNameAndExplicitLocalTile() {
        XCTAssertEqual(MeetTileEvidence.name("Alice (You)", isLocal: true), "Alice")
        XCTAssertNil(MeetTileEvidence.name("You", isLocal: true))
        XCTAssertNil(MeetTileEvidence.name("Alice (You)", isLocal: false))
    }
    func testOfflineCombinedRefreshUsesOneCacheAndRejectsChangedOriginals() async throws {
        let dir = try directory(), meta = try session(dir)
        let prepared = try await MeetingAudio.prepare(in: dir, meta: meta)
        let response = ElevenLabsEngine.Response(language_code: "eng", language_probability: 1, text: "Hello.",
            words: [.init(text: "Hello.", start: 0.2, end: 0.8, type: "word", speaker_id: "speaker_0")])
        let cache = ElevenLabsEngine.Cache(version: ElevenLabsEngine.cacheVersion, model: "scribe_v2",
            audioSHA256: prepared.manifest.audio_sha256, response: response)
        try JSONEncoder().encode(cache).write(to: dir.appendingPathComponent(MeetingAudio.cacheName))
        let track = SessionMeta.Track(file: MeetingAudio.filename, speaker: "meeting", offsetMs: 0)
        let built = ElevenLabsTranscripts.build(meta: meta,
            tracks: [.init(track: track, segments: try ElevenLabsEngine.segments(response), meetingAudio: prepared.manifest)],
            roster: .init(audio_started_at: 1000), observations: [])
        try built.write(to: dir)
        let original = try Data(contentsOf: dir.appendingPathComponent("transcript.json"))
        try await RefreshSpeakers.parse([dir.path]).refresh()
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("transcript.json")), original)
        try Data("changed microphone".utf8).write(to: dir.appendingPathComponent("mic.caf"))
        do { try await RefreshSpeakers.parse([dir.path]).refresh(); XCTFail("Changed original audio must invalidate combined refresh") }
        catch { XCTAssertTrue(error is ValidationError) }
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("transcript.json")), original)
    }

}

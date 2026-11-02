import XCTest
@testable import quill

private actor DiarizedScribeStub: TranscriptionEngine {
    nonisolated let name = "elevenlabs"
    nonisolated let model = "scribe_v2"
    func prepare() async throws {}
    func release() async {}
    func transcribe(_ audio: URL) async throws -> [TranscriptSegment] {
        [.init(start: 0, end: 2, text: "Hello.", words: [.init(start: 0, end: 2, text: "Hello.")], speakerID: "speaker_0")]
    }
}

final class ElevenLabsTranscriptsTests: XCTestCase, @unchecked Sendable {
    private let track = SessionMeta.Track(file: "system.caf", speaker: "them", offsetMs: 0)
    private func segment(_ speaker: String? = "speaker_0", start: Double = 0, end: Double = 20, text: String = "Hello.") -> TranscriptSegment {
        .init(start: start, end: end, text: text, words: [.init(start: start, end: end, text: text)], speakerID: speaker)
    }
    private func observations(_ name: String, from start: Double, to end: Double, origin: Double = 1000) -> [SpeakerObservation] {
        stride(from: start + 0.125, through: end - 0.125, by: 0.25).map {
            .init(observed_at: origin + $0, meeting_id: "test", names: [name], source: "meeting_tile")
        }
    }
    private func build(_ segments: [TranscriptSegment], _ samples: [SpeakerObservation]) -> ElevenLabsTranscripts.Output {
        let meta = SessionMeta(tracks: [track], audioStartedAt: 1000, localSpeakerName: "Local", sharedMicrophone: false, meetingTitle: "Weekly planning")
        return ElevenLabsTranscripts.build(meta: meta, tracks: [.init(track: track, segments: segments)],
            roster: ParticipantRoster(audio_started_at: 1000), observations: samples, createdAt: "fixture")
    }
    private func directory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("quill-cloud-mapping-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: dir) }
        return dir
    }

    func testExactly95PercentPassesAndBelow95Fails() {
        let passing = build([segment()], observations("Alice", from: 0, to: 19) + observations("Bob", from: 19, to: 20))
        XCTAssertTrue(passing.report.accepted)
        XCTAssertEqual(passing.report.speakers[0].agreement, 0.95, accuracy: 0.000001)
        XCTAssertEqual(passing.named?.segments[0].speaker_name, "Alice")
        XCTAssertNil(passing.original.segments[0].speaker_name)
        let failing = build([segment(end: 50)], observations("Alice", from: 0, to: 47) + observations("Bob", from: 47, to: 50))
        XCTAssertEqual(failing.report.speakers[0].agreement, 0.94, accuracy: 0.000001)
        XCTAssertFalse(failing.report.accepted)
        XCTAssertNil(failing.named)
    }

    func testEveryRemoteSpeakerMustPassIncludingMissingOrNullSpeakers() {
        let segments = [segment(start: 0, end: 2), segment("speaker_1", start: 3, end: 5)]
        let incomplete = build(segments, observations("Alice", from: 0, to: 2))
        XCTAssertEqual(incomplete.report.speakers.count, 2)
        XCTAssertNil(incomplete.named)
        let complete = build(segments, observations("Alice", from: 0, to: 2) + observations("Bob", from: 3, to: 5))
        XCTAssertEqual(complete.named?.segments.compactMap(\.speaker_name), ["Alice", "Bob"])
        let unknown = build([segment(nil)], observations("Alice", from: 0, to: 20))
        XCTAssertFalse(unknown.report.accepted)
        XCTAssertNil(unknown.named)
    }

    func testNoEvidenceDoesNotUseRosterOrLocalNameToGuessRemoteNames() {
        let output = build([segment()], [])
        XCTAssertNil(output.named)
        XCTAssertEqual(output.report.speakers[0].agreement, 0)
        XCTAssertEqual(output.report.speakers[0].observed_seconds, 0)
    }

    func testUnobservedSpeechIsExcludedButCoverageIsReported() {
        let output = build([segment(end: 100)], observations("Alice", from: 0, to: 2))
        XCTAssertTrue(output.report.accepted)
        XCTAssertEqual(output.report.speakers[0].agreement, 1)
        XCTAssertEqual(output.report.speakers[0].observed_fraction, 0.02, accuracy: 0.000001)
    }

    func testDuplicateEvidenceDoesNotOutvoteAConflict() {
        let alice = observations("Alice", from: 0, to: 10)
        let bob = observations("Bob", from: 10, to: 20)
        let output = build([segment()], Array(repeating: alice, count: 20).flatMap { $0 } + bob)
        XCTAssertFalse(output.report.accepted)
        XCTAssertEqual(output.report.speakers[0].agreement, 0.5, accuracy: 0.000001)
        XCTAssertEqual(output.report.speakers[0].observed_seconds, 20, accuracy: 0.000001)
    }

    func testShortContradictoryObservationCountsAgainstAgreement() {
        let samples = observations("Alice", from: 0, to: 1) + [SpeakerObservation(
            observed_at: 1001.125, meeting_id: "test", names: ["Bob"], source: "meeting_tile")]
        let output = build([segment(end: 1.25)], samples)
        XCTAssertEqual(output.report.speakers[0].agreement, 0.8, accuracy: 0.000001)
        XCTAssertFalse(output.report.accepted)
    }

    func testConflictingTimelinesAndOverlappingSpeakersCannotBothGetTheSameName() {
        // Two observations for the same time with different names are ambiguous.
        let mixed = build([segment()], observations("Alice", from: 0, to: 20)
            + observations("Bob", from: 0, to: 20).map {
                var sample = $0; sample.source = "zoom_border"; return sample
            })
        XCTAssertFalse(mixed.report.accepted)
        XCTAssertGreaterThan(mixed.report.speakers[0].ambiguous_seconds, 19)
        let overlap = build([segment(), segment("speaker_1")], observations("Alice", from: 0, to: 20))
        XCTAssertFalse(overlap.report.accepted)
        XCTAssertTrue(overlap.report.speakers.allSatisfy { $0.agreement == 0 })
    }

    func testSilenceInsideSentenceDoesNotVoteAndCaptionTextDoesNotEstablishVoiceName() {
        let speech = TranscriptSegment(start: 0, end: 20, text: "Hello again.", words: [
            .init(start: 0, end: 2, text: "Hello"), .init(start: 18, end: 20, text: "again.")], speakerID: "speaker_0")
        let output = build([speech], observations("Alice", from: 0, to: 2)
            + observations("Bob", from: 2, to: 18) + observations("Alice", from: 18, to: 20))
        XCTAssertTrue(output.report.accepted)
        XCTAssertEqual(output.report.speakers[0].speech_seconds, 4, accuracy: 0.000001)
        XCTAssertEqual(output.report.speakers[0].agreement, 1)
        let captions = [SpeakerObservation(observed_at: 1020, meeting_id: "test", names: ["Alice"], source: "meeting_caption", text: "One two three four five")]
        XCTAssertNil(build([segment(text: "One two three four five")], captions).named)
    }

    func testOffsetsTrackScopedProviderIDsMetadataAndOriginalArePreserved() throws {
        let mic = SessionMeta.Track(file: "mic.caf", speaker: "me", offsetMs: 100)
        let remote = SessionMeta.Track(file: "system.caf", speaker: "them", offsetMs: 250)
        let meta = SessionMeta(tracks: [mic, remote], audioStartedAt: 1000, localSpeakerName: "Local", sharedMicrophone: false, meetingTitle: "Weekly planning")
        var roster = ParticipantRoster(audio_started_at: 1000)
        roster.observe(.init(observed_at: 1000, meeting_id: "test", names: ["Alice"]), localName: "Local")
        let output = ElevenLabsTranscripts.build(meta: meta, tracks: [.init(track: mic, segments: [segment(end: 2)]),
            .init(track: remote, segments: [segment(end: 2)])], roster: roster,
            observations: observations("Alice", from: 0, to: 2, origin: 1000.25))
        XCTAssertEqual(output.original.segments.map(\.start_ms), [100, 250])
        XCTAssertEqual(output.original.segments.map(\.provider_speaker_id), ["speaker_0", "speaker_0"])
        XCTAssertEqual(Set(output.original.segments.map(\.speaker)).count, 2)
        XCTAssertTrue(output.original.segments.allSatisfy { $0.speaker_name == nil })
        XCTAssertEqual(output.named?.segments.compactMap(\.speaker_name), ["Local", "Alice"])
        XCTAssertEqual(output.named?.segments.map(\.speaker), output.original.segments.map(\.speaker))
        XCTAssertEqual(output.named?.segments.map(\.text), output.original.segments.map(\.text))
        XCTAssertEqual(output.named?.segments.map(\.end_ms), output.original.segments.map(\.end_ms))
        let dir = try directory()
        try output.write(to: dir)
        for base in ["transcript", "transcript-named"] {
            let text = try String(contentsOf: dir.appendingPathComponent(base + ".md"), encoding: .utf8)
            XCTAssertTrue(text.hasPrefix("# Weekly planning"))
            XCTAssertTrue(text.contains("## Participants"))
            XCTAssertTrue(text.contains("Alice"))
            let json = try JSONDecoder().decode(Transcript.self, from: Data(contentsOf: dir.appendingPathComponent(base + ".json")))
            XCTAssertEqual(json.meeting_title, "Weekly planning")
            XCTAssertEqual(json.participant_roster?.participants[0].name, "Alice")
        }
        try build([segment()], []).write(to: dir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("transcript-named.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("transcript-named.md").path))
    }

    func testCoordinatorNeverRunsLocalDiarizationWithElevenLabsAndCleanupDoesNotEditOriginal() async throws {
        let dir = try directory()
        // Decode real synthetic audio for the mix; only the stub cloud engine runs ASR.
        try AudioTestSupport.write(dir.appendingPathComponent("system.caf"))
        try Data(#"{"files":{"system":"system.caf"},"audio_started_at":1000,"meeting_title":"Planning"}"#.utf8)
            .write(to: dir.appendingPathComponent("meta.json"))
        let coordinator = TranscriptionCoordinator { _, _ in DiarizedScribeStub() }
        try await coordinator.transcribe(dir, detectSpeakers: true, engineOverride: .elevenLabs)
        let url = dir.appendingPathComponent("transcript.json"), original = try Data(contentsOf: url)
        let transcript = try JSONDecoder().decode(Transcript.self, from: original)
        XCTAssertEqual(transcript.speaker_detection?["meeting"], "elevenlabs")
        XCTAssertEqual(transcript.segments[0].provider_speaker_id, "speaker_0")
        XCTAssertEqual(transcript.variant, "elevenlabs_original")
        XCTAssertEqual(transcript.meeting_title, "Planning")
        let report = await TranscriptPostProcessor.process(dir, options: .init(mode: .auto)) { _, _ in
            XCTFail("Cloud originals must never invoke text cleanup"); return nil
        }
        XCTAssertEqual(report.status, "skipped_elevenlabs_original")
        XCTAssertEqual(try Data(contentsOf: url), original)
    }
}

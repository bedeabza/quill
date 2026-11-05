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

    func testUnobservedSpeechIsExcludedFromAgreementButCoverageNeedsAQuarter() {
        let thin = build([segment(end: 100)], observations("Alice", from: 0, to: 2))
        XCTAssertEqual(thin.report.speakers[0].agreement, 1)
        XCTAssertEqual(thin.report.speakers[0].observed_fraction, 0.02, accuracy: 0.000001)
        XCTAssertFalse(thin.report.accepted)
        XCTAssertNil(thin.named)
        let quarter = build([segment(end: 100)], observations("Alice", from: 0, to: 25))
        XCTAssertEqual(quarter.report.speakers[0].observed_fraction, 0.25, accuracy: 0.000001)
        XCTAssertTrue(quarter.report.accepted)
    }

    /// Recording 2026.11.05-1346 (Teams): the remote participant never spoke, but
    /// line noise lit her border. One sample survived a 16 ms remote-only window
    /// in a pause, giving 0.012 s of "Helen" over the local voice's words.
    func testMillisecondsOfNoisyRemoteBorderCannotNameAWholeVoice() {
        let track = SessionMeta.Track(file: MeetingAudio.filename, speaker: "meeting", offsetMs: 0)
        let manifest = MeetingAudio.Manifest(version: 1, algorithm: "fixture", sample_rate: 16000, inputs: [], audio_sha256: "fixture",
            frames: 16000 * 140, microphone_energy: 0, cleaned_microphone_energy: 0, system_energy: 0,
            local_windows: [], remote_windows: [.init(start: 120.576, end: 120.592)])
        let turns: [(Double, Double)] = [(118.74, 119.02), (120.18, 120.24), (120.32, 120.52), (120.58, 120.68), (120.7, 120.86),
            (120.9, 121.22), (121.68, 121.74), (121.8, 122), (122.04, 122.32), (122.42, 122.64), (122.68, 122.82),
            (122.9, 123.26), (123.32, 123.58), (127.58, 133), (133.1, 138.28)]
        let voice = TranscriptSegment(start: 118.74, end: 138.28, text: "I'm gonna talk for about 10 seconds.",
            words: turns.map { .init(start: $0.0, end: $0.1, text: "word") }, speakerID: "speaker_0")
        let border = SpeakerObservation(observed_at: 1000 + 120.5, meeting_id: "test", names: ["Helen"], source: "meeting_tile")
        let output = ElevenLabsTranscripts.build(meta: .init(tracks: [track], audioStartedAt: 1000, localSpeakerName: "Dragos Badea",
            sharedMicrophone: false), tracks: [.init(track: track, segments: [voice], meetingAudio: manifest)],
            roster: .init(audio_started_at: 1000), observations: [border])
        let speaker = output.report.speakers[0]
        XCTAssertEqual(speaker.candidate_name, "Helen")
        XCTAssertEqual(speaker.agreement, 1)
        XCTAssertEqual(speaker.observed_seconds, 0.012, accuracy: 0.000001)
        XCTAssertLessThan(speaker.observed_fraction, 0.001)
        XCTAssertFalse(speaker.accepted)
        XCTAssertNil(output.named)
    }

    private func combined(_ segments: [TranscriptSegment], local: [(Double, Double)], remote: [(Double, Double)],
                          roster names: [String], observations: [SpeakerObservation] = [],
                          inferNames: Bool = true) -> ElevenLabsTranscripts.Output {
        let track = SessionMeta.Track(file: MeetingAudio.filename, speaker: "meeting", offsetMs: 0)
        let manifest = MeetingAudio.Manifest(version: 1, algorithm: "fixture", sample_rate: 16000, inputs: [], audio_sha256: "fixture",
            frames: 16000 * 200, microphone_energy: 0, cleaned_microphone_energy: 0, system_energy: 0,
            local_windows: local.map { .init(start: $0.0, end: $0.1) }, remote_windows: remote.map { .init(start: $0.0, end: $0.1) })
        var roster = ParticipantRoster(audio_started_at: 1000)
        roster.observe(.init(observed_at: 1000, meeting_id: "local", names: ["Dragos Badea"], source: "local_microphone", is_local: true),
                       localName: "Dragos Badea")
        roster.observe(.init(observed_at: 1000, meeting_id: "test", names: [], source: "meeting_roster",
                             participants: names.map { .init(name: $0, is_local: false) }), localName: "Dragos Badea")
        return ElevenLabsTranscripts.build(meta: .init(tracks: [track], audioStartedAt: 1000, localSpeakerName: "Dragos Badea",
            sharedMicrophone: false), tracks: [.init(track: track, segments: segments, meetingAudio: manifest)],
            roster: roster, observations: observations, inferNames: inferNames)
    }

    /// Recording 2026.11.05-1704 (Teams 1:1 call): no tile evidence for either
    /// voice. One voice is almost only microphone, the other remote.
    func testTwoPersonCallIsNamedByMicrophoneMajorityThenElimination() {
        let voices = [segment(start: 0, end: 60), segment("speaker_1", start: 60, end: 100)]
        let output = combined(voices, local: [(0, 50), (61, 62)], remote: [(59.5, 60), (62, 90)], roster: ["Patranca, Bogdan - CTP"])
        XCTAssertTrue(output.report.accepted)
        XCTAssertEqual(output.report.speakers.map(\.name), ["Dragos Badea", "Patranca, Bogdan - CTP"])
        XCTAssertEqual(output.report.speakers.map(\.attribution), ["local_microphone_majority", "roster_elimination"])
        XCTAssertEqual(output.report.speakers.map(\.accepted), [false, false], "inferred names never pass as evidence")
        XCTAssertEqual(output.report.speakers[0].local_seconds ?? 0, 50, accuracy: 0.000001)
        XCTAssertEqual(output.named?.segments.map(\.attribution), ["local_microphone_majority", "roster_elimination"])
        XCTAssertTrue(output.original.segments.allSatisfy { $0.speaker_name == nil })
        XCTAssertNil(combined(voices, local: [(0, 50)], remote: [(62, 90)], roster: ["Patranca, Bogdan - CTP"], inferNames: false).named)
    }

    func testInferenceNeedsOneClearMicrophoneVoiceAndMatchingCounts() {
        let two = [segment(start: 0, end: 60), segment("speaker_1", start: 60, end: 100)]
        // A second voice that is mostly microphone too (someone in the room).
        let room = combined(two, local: [(0, 50), (60, 80)], remote: [(80, 90)], roster: ["Bob"])
        XCTAssertEqual(room.report.speakers.compactMap(\.name), [])
        // Below 90% microphone: no local name, so nothing is left to eliminate.
        let unclear = combined(two, local: [(0, 40)], remote: [(40, 50), (62, 90)], roster: ["Bob"])
        XCTAssertNil(unclear.named)
        XCTAssertEqual(unclear.report.speakers.compactMap(\.name), [])
        // Two remote names for one remote voice: elimination does not guess.
        let crowd = combined(two, local: [(0, 50)], remote: [(62, 90)], roster: ["Bob", "Carol"])
        XCTAssertEqual(crowd.report.speakers.compactMap(\.name), ["Dragos Badea"])
        XCTAssertNil(crowd.named)
        // Three voices, two people: elimination does not apply either.
        let split = combined(two + [segment("speaker_2", start: 100, end: 120)], local: [(0, 50)], remote: [(62, 120)], roster: ["Bob"])
        XCTAssertNil(split.named)
    }

    func testEvidenceForSomeoneElseBlocksElimination() {
        let two = [segment(start: 0, end: 60), segment("speaker_1", start: 60, end: 100)]
        // Carol's tile covers 30% of the remote voice at 80%: short of the gate, but
        // it contradicts the roster's only remote name.
        let samples = observations("Carol", from: 62, to: 72) + observations("Bob", from: 72, to: 74.5)
        let blocked = combined(two, local: [(0, 50)], remote: [(60, 100)], roster: ["Bob"], observations: samples)
        XCTAssertEqual(blocked.report.speakers.compactMap(\.name), ["Dragos Badea"])
        XCTAssertNil(blocked.named)
        // Matching evidence below the gate does not block it.
        let agreeing = combined(two, local: [(0, 50)], remote: [(60, 100)], roster: ["Bob"], observations: observations("Bob", from: 62, to: 64))
        XCTAssertEqual(agreeing.report.speakers.compactMap(\.attribution), ["local_microphone_majority", "roster_elimination"])
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

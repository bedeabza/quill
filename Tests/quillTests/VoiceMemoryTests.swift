import FluidAudio
import XCTest
@testable import quill

final class VoiceMemoryTests: XCTestCase, @unchecked Sendable {
    func vector(_ index: Int) -> [Float] { var v = Array(repeating: Float(0), count: 256); v[index] = 1; return v }
    func analysis(_ index: Int = 0, name: String? = nil) -> SpeakerAnalysis {
        let samples = (0..<12).map { VoiceSample(speaker_id: "system_1", start: Double($0 * 10), end: Double($0 * 10 + 8), embedding: vector(index)) }
        let identity = name.map { SpeakerIdentity(name: $0, source: "meeting_tile", evidence_count: 20) }
        return SpeakerAnalysis(turns: samples.map { .init(speaker_id: $0.speaker_id, start: $0.start, end: $0.end) }, names: [:],
            named_spans: identity.map { id in samples.map { .init(start: $0.start, end: $0.end, identity: id) } } ?? [],
            voice_identities: name.map { ["system_1": .init(name: $0, source: "meeting_voice", evidence_count: 4)] }, voice_samples: samples)
    }

    func testVerifiedEnrollmentMatchesLaterMeetingAndDoesNotTrainOnPrediction() {
        var memory = VoiceMemory()
        XCTAssertEqual(memory.learn(analysis(name: "Andrei"), recording: "first"), 1)
        XCTAssertEqual(memory.identities(for: analysis(), roster: nil)["system_1"]?.name, "Andrei")
        XCTAssertTrue(memory.identities(for: analysis(), roster: nil, excludingRecording: "first").isEmpty)
        var predicted = analysis()
        predicted.voice_identities = memory.identities(for: predicted, roster: nil)
        XCTAssertEqual(memory.learn(predicted, recording: "second"), 0)
        XCTAssertEqual(memory.learn(analysis(name: "Andrei"), recording: "first"), 0)
        XCTAssertEqual(memory.profiles[0].exemplars.count, 4)
    }

    func testUnknownVoiceAmbiguityAndConflictingUIStayUnnamed() {
        var memory = VoiceMemory()
        _ = memory.learn(analysis(name: "Andrei"), recording: "one")
        XCTAssertTrue(memory.identities(for: analysis(1), roster: nil).isEmpty)
        var conflict = analysis(name: "Someone else"); conflict.voice_identities = nil
        XCTAssertTrue(memory.identities(for: conflict, roster: nil).isEmpty)
        _ = memory.learn(analysis(name: "Same sounding person"), recording: "two")
        XCTAssertTrue(memory.identities(for: analysis(), roster: nil).isEmpty)
    }

    func testRosterExclusionShortSamplesAndInvalidVectorsAreRejected() {
        var memory = VoiceMemory()
        _ = memory.learn(analysis(name: "Andrei"), recording: "one")
        var roster = ParticipantRoster(audio_started_at: 0)
        roster.participants = [.init(name: "Emil", is_local: false, first_seen: 0, last_seen: 50, sources: ["meeting_roster"])]
        XCTAssertTrue(memory.identities(for: analysis(), roster: roster).isEmpty)
        var short = analysis(); short.voice_samples = Array(short.voice_samples!.prefix(2))
        XCTAssertTrue(memory.identities(for: short, roster: nil).isEmpty)
        XCTAssertNil(VoiceMemory.normalized([.nan]))
        XCTAssertNil(VoiceMemory.normalized(Array(repeating: 0, count: 256)))
        var bad = vector(0); bad[1] = .infinity
        XCTAssertNil(VoiceMemory.normalized(bad))
    }

    func testOverlappingWindowsAndMixedSpeechCannotEnroll() {
        var mixed = analysis(name: "Andrei"), memory = VoiceMemory()
        mixed.turns.append(.init(speaker_id: "system_2", start: 0, end: 150))
        XCTAssertEqual(memory.learn(mixed, recording: "one"), 0)
        let sample = analysis().voice_samples!.first!
        XCTAssertEqual(VoiceMemory.cleanSamples(Array(repeating: sample, count: 20), turns: analysis().turns).count, 1)
        var caption = analysis(name: "Andrei")
        caption.named_spans = caption.named_spans.map { .init(start: $0.start, end: $0.end, identity: .init(name: "Andrei", source: "meeting_caption", evidence_count: 20)) }
        XCTAssertEqual(memory.learn(caption, recording: "two"), 0)
    }

    func testMergedClusterWithAnUnknownVoiceDoesNotInheritKnownName() {
        var memory = VoiceMemory()
        _ = memory.learn(analysis(name: "Andrei"), recording: "one")
        var mixed = analysis()
        mixed.voice_samples = mixed.voice_samples!.enumerated().map { index, sample in
            VoiceSample(speaker_id: sample.speaker_id, start: sample.start, end: sample.end,
                        embedding: vector(index >= 9 ? 1 : 0))
        }
        XCTAssertTrue(memory.identities(for: mixed, roster: nil).isEmpty)
    }

    func testCleanNamedWindowsCanEnrollPeopleFromOneMixedAcousticCluster() {
        var first = analysis(name: "Alice"), second = analysis(1, name: "Bob")
        second.turns = second.turns.map { .init(speaker_id: $0.speaker_id, start: $0.start + 150, end: $0.end + 150) }
        second.named_spans = second.named_spans.map { .init(start: $0.start + 150, end: $0.end + 150, identity: $0.identity) }
        second.voice_samples = second.voice_samples?.map { .init(speaker_id: $0.speaker_id, start: $0.start + 150, end: $0.end + 150, embedding: $0.embedding) }
        first.turns += second.turns
        first.named_spans += second.named_spans
        first.voice_samples! += second.voice_samples!
        first.voice_identities = [:]
        XCTAssertTrue(SpeakerAttribution.voiceNames(turns: first.turns, spans: first.named_spans).isEmpty)
        var memory = VoiceMemory()
        XCTAssertEqual(memory.learn(first, recording: "mixed"), 2)
        XCTAssertEqual(Set(memory.profiles.map(\.name)), ["Alice", "Bob"])
        XCTAssertEqual(memory.identities(for: analysis(), roster: nil)["system_1"]?.name, "Alice")
        XCTAssertEqual(memory.identities(for: analysis(1), roster: nil)["system_1"]?.name, "Bob")
    }

    func testCompetingNamesWithinEachWindowNeverEnroll() {
        var input = analysis(name: "Alice")
        input.named_spans += input.named_spans.map {
            .init(start: $0.start + 1, end: $0.end - 1, identity: .init(name: "Bob", source: "meeting_tile", evidence_count: 20))
        }
        var memory = VoiceMemory()
        XCTAssertEqual(memory.learn(input, recording: "overlap"), 0)
    }

    func testRecordedMixedClusterCanEnrollVerifiedWindows() throws {
        guard let path = ProcessInfo.processInfo.environment["QUILL_TEST_MIXED_VOICE_ANALYSIS"] else {
            throw XCTSkip("Set QUILL_TEST_MIXED_VOICE_ANALYSIS for the recorded mixed-cluster enrollment regression")
        }
        let analysis = try JSONDecoder().decode(SpeakerAnalysis.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        XCTAssertTrue(analysis.voice_identities?.isEmpty == true)
        var memory = VoiceMemory()
        XCTAssertGreaterThan(memory.learn(analysis, recording: "isolated-test-recording"), 0)
        print("Verified sample enrollment from mixed clusters: \(memory.profiles.map(\.name))")
        XCTAssertTrue(memory.profiles.allSatisfy { profile in
            analysis.named_spans.contains { $0.identity.name == profile.name && $0.identity.source == "meeting_tile" }
        })
    }

    func testStorePersistsPrivatelyAndPreservesCorruptData() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = VoiceMemoryStore(url: dir.appendingPathComponent("profiles.json"))
        try store.update { _ = $0.learn(analysis(name: "Andrei"), recording: "one") }
        XCTAssertEqual(try store.read().profiles.first?.name, "Andrei")
        let mode = try FileManager.default.attributesOfItem(atPath: store.url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
        try Data("broken".utf8).write(to: store.url)
        XCTAssertThrowsError(try store.update { $0.profiles = [] })
        XCTAssertEqual(try String(contentsOf: store.url, encoding: .utf8), "broken")
    }

    func testRealVoiceHeldOutAudio() async throws {
        guard let path = ProcessInfo.processInfo.environment["QUILL_TEST_VOICE_RECORDING"] else {
            throw XCTSkip("Set QUILL_TEST_VOICE_RECORDING for the local voice fingerprint regression")
        }
        ModelHub.offlineMode = true
        let dir = URL(fileURLWithPath: path), meta = try SessionMeta.read(from: dir)
        let track = try XCTUnwrap(meta.tracks.first { $0.source == "system" })
        var all = try await SpeakerDiarizer.analyze(dir.appendingPathComponent(track.file), source: "system", captureVoiceSamples: true)
        let observations = try String(contentsOf: dir.appendingPathComponent("speaker-observations.jsonl"), encoding: .utf8)
            .split(separator: "\n").map { try JSONDecoder().decode(SpeakerObservation.self, from: Data($0.utf8)) }
        all.named_spans = SpeakerAttribution.nameSpans(turns: all.turns, observations: observations,
            audioStartedAt: try XCTUnwrap(meta.audioStartedAt) + Double(track.offsetMs) / 1000, segments: [])
        all.voice_identities = SpeakerAttribution.voiceNames(turns: all.turns, spans: all.named_spans)
        if let output = ProcessInfo.processInfo.environment["QUILL_TEST_VOICE_DIAGNOSTIC"] {
            try JSONEncoder().encode(all).write(to: URL(fileURLWithPath: output))
        }
        let midpoint = (all.turns.map(\.end).max() ?? 0) / 2
        var training = all; training.voice_samples = all.voice_samples?.filter { $0.end < midpoint }
        var memory = VoiceMemory()
        let learned = memory.learn(training, recording: "training-half")
        var heldOut = all; heldOut.voice_samples = all.voice_samples?.filter { $0.start > midpoint }
        heldOut.voice_identities = nil; heldOut.named_spans = []
        let matches = memory.identities(for: heldOut, roster: nil)
        print("Voice regression: \(all.voice_samples?.count ?? 0) clean samples, \(learned) profiles, held-out matches \(matches)")
        XCTAssertGreaterThan(learned, 0)
        XCTAssertFalse(matches.isEmpty)
        XCTAssertTrue(matches.values.allSatisfy { identity in all.voice_identities?.values.contains(where: { $0.name == identity.name }) == true })
        if let independent = ProcessInfo.processInfo.environment["QUILL_TEST_HELD_OUT_VOICE"] {
            let later = try await SpeakerDiarizer.analyze(URL(fileURLWithPath: independent), source: "system", captureVoiceSamples: true)
            if let output = ProcessInfo.processInfo.environment["QUILL_TEST_VOICE_DIAGNOSTIC"] {
                try JSONEncoder().encode(later).write(to: URL(fileURLWithPath: output + ".later"))
            }
            let independentMatches = memory.identities(for: later, roster: nil)
            print("Independent later recording matches: \(independentMatches)")
            XCTAssertFalse(independentMatches.isEmpty)
            XCTAssertTrue(independentMatches.values.allSatisfy { identity in all.voice_identities?.values.contains(where: { $0.name == identity.name }) == true })
        }
        if let other = ProcessInfo.processInfo.environment["QUILL_TEST_UNKNOWN_VOICE"] {
            let unknown = try await SpeakerDiarizer.analyze(URL(fileURLWithPath: other), source: "system", captureVoiceSamples: true)
            if let output = ProcessInfo.processInfo.environment["QUILL_TEST_VOICE_DIAGNOSTIC"] {
                try JSONEncoder().encode(unknown).write(to: URL(fileURLWithPath: output + ".unknown"))
            }
            XCTAssertTrue(memory.identities(for: unknown, roster: nil).isEmpty, "An unknown speaker must not inherit the enrolled person's name")
        }
    }
}

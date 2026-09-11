import XCTest
@testable import quill

final class TranscriptPostProcessorTests: XCTestCase {
    private func fixture() -> Transcript {
        Transcript(engine: "fixture", model: "fixture", created_at: "2026-09-10T00:00:00Z", segments: [
            .init(speaker: "me", start_ms: 100, end_ms: 900, text: "We use teh platform.", source: "mic", speaker_name: "Alice", attribution: "local_microphone"),
            .init(speaker: "system_1", start_ms: 1000, end_ms: 2000, text: "My name is Bob.", source: "system", attribution: "diarization")
        ], schema_version: 2)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("quill-cleanup-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func recording() throws -> URL {
        let directory = try temporaryDirectory()
        try Data(#"{"files":{"system":"system.caf"},"ended":"2026-09-10T00:00:00Z"}"#.utf8)
            .write(to: directory.appendingPathComponent("meta.json"))
        try fixture().write(to: directory)
        return directory
    }

    private func fakeHarness(response: String) throws -> TranscriptHarness {
        let executable = try temporaryDirectory().appendingPathComponent("codex")
        let quoted = "'" + response.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let script = """
        #!/bin/sh
        while [ "$#" -gt 0 ]; do
          if [ "$1" = "--output-last-message" ]; then shift; output="$1"; fi
          shift
        done
        cat >/dev/null
        printf '%s' \(quoted) > "$output"
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return TranscriptHarness(kind: .codex, executable: executable)
    }

    func testSettingsDefaultOffAndInvalidModeNeverEnablesCloud() {
        XCTAssertEqual(PostProcessingOptions(json: nil).mode, .off)
        XCTAssertEqual(PostProcessingOptions(json: ["mode": "typo"]).mode, .off)
        XCTAssertEqual(PostProcessingOptions(json: ["mode": "auto"]).mode, .auto)
        XCTAssertEqual(PostProcessingOptions(timeout: .infinity).timeout, 120)
        XCTAssertEqual(PostProcessingOptions(timeout: 10000).timeout, 600)
        XCTAssertNil(TranscriptHarness.find(.codex, searchPaths: []))
        XCTAssertNil(TranscriptHarness.find(.claude, searchPaths: []))
    }

    func testAutoPrefersActiveHarnessAndExplicitChoiceDoesNotFallBack() {
        XCTAssertEqual(TranscriptHarness.preference(mode: .auto, activeApps: ["com.anthropic.claudefordesktop"]), [.claude, .codex])
        XCTAssertEqual(TranscriptHarness.preference(mode: .auto, activeApps: ["com.openai.codex"]), [.codex, .claude])
        XCTAssertEqual(TranscriptHarness.preference(mode: .claude, activeApps: ["com.openai.codex"]), [.claude])
        XCTAssertEqual(TranscriptHarness.preference(mode: .off, activeApps: ["com.openai.codex"]), [])
    }

    func testHarnessInvocationsDisableAmbientToolsAndSessionPersistence() throws {
        let directory = try temporaryDirectory()
        let schema = directory.appendingPathComponent("schema.json")
        try TranscriptPostProcessor.schema.write(to: schema)
        for kind in [PostProcessingMode.codex, .claude] {
            let harness = TranscriptHarness(kind: kind, executable: URL(fileURLWithPath: "/unused"))
            let args = try harness.arguments(schema: schema, output: directory.appendingPathComponent("result.json"))
            XCTAssertFalse(args.contains("--dangerously-bypass-approvals-and-sandbox"))
            XCTAssertFalse(args.contains("--dangerously-skip-permissions"))
            if kind == .codex {
                XCTAssertTrue(args.contains("--ignore-user-config"))
                XCTAssertTrue(args.contains("--ephemeral"))
                XCTAssertTrue(args.contains("read-only"))
                XCTAssertTrue(args.contains("shell_tool"))
            } else {
                XCTAssertTrue(args.contains("--safe-mode"))
                XCTAssertEqual(args[try XCTUnwrap(args.firstIndex(of: "--tools")) + 1], "")
                XCTAssertTrue(args.contains("--no-session-persistence"))
            }
        }
        XCTAssertNil(HarnessProcess.environment()["OPENAI_API_KEY"])
        XCTAssertNil(HarnessProcess.environment()["ANTHROPIC_API_KEY"])
    }

    func testConservativeCorrectionPreservesTimingIDsAndExistingNames() throws {
        let original = fixture()
        let response = TranscriptCorrections(edits: [.init(segment_index: 0, original_text: original.segments[0].text, text: "We use the platform.")],
                                             speaker_suggestions: [.init(segment_indices: [1], name: "Bob", evidence_segment_indices: [1], reason: "Explicit introduction.")])
        let output = try TranscriptPostProcessor.validate(response, transcript: original)
        XCTAssertEqual(output.segments[0].text, "We use the platform.")
        XCTAssertEqual(output.segments.map(\.start_ms), original.segments.map(\.start_ms))
        XCTAssertEqual(output.segments.map(\.end_ms), original.segments.map(\.end_ms))
        XCTAssertEqual(output.segments.map(\.speaker), original.segments.map(\.speaker))
        XCTAssertEqual(output.segments.map(\.speaker_name), original.segments.map(\.speaker_name))
        XCTAssertNil(output.segments[1].speaker_name, "Speaker suggestions must not become verified names")
    }

    func testMismatchedDuplicateAndInventedSegmentsAreRejected() {
        for edits in [
            [TranscriptCorrections.Edit(segment_index: 9, original_text: "x", text: "y")],
            [.init(segment_index: 0, original_text: "wrong original", text: "We use the platform.")],
            Array(repeating: .init(segment_index: 0, original_text: "We use teh platform.", text: "We use the platform."), count: 2)
        ] {
            XCTAssertThrowsError(try TranscriptPostProcessor.validate(.init(edits: edits, speaker_suggestions: []), transcript: fixture()))
        }
    }

    func testNumbersNegationsAndMajorRewritesAreRejected() {
        for (old, new) in [("We owe -100.", "We owe 100."), ("We pay 100.", "We pay 200."),
                           ("We can do it.", "We cannot do it."), ("Nu putem merge.", "Putem merge."),
                           ("Hello everyone.", "We agreed to buy the company."), ("Salut", "Hello")] {
            var original = fixture()
            original.segments[0].text = old
            XCTAssertThrowsError(try TranscriptPostProcessor.validate(.init(edits: [.init(segment_index: 0, original_text: old, text: new)],
                                                                          speaker_suggestions: []), transcript: original), "\(old) -> \(new)")
        }
    }

    func testSpeakerSuggestionsRequireExistingUnnamedSegmentsAndNameEvidence() {
        for suggestion in [
            TranscriptCorrections.SpeakerSuggestion(segment_indices: [0], name: "Bob", evidence_segment_indices: [1], reason: "Already named target"),
            .init(segment_indices: [1], name: "Invented Person", evidence_segment_indices: [1], reason: "Guess"),
            .init(segment_indices: [1], name: "Bob", evidence_segment_indices: [99], reason: "Invalid evidence")
        ] {
            XCTAssertThrowsError(try TranscriptPostProcessor.validate(.init(edits: [], speaker_suggestions: [suggestion]), transcript: fixture()))
        }
    }

    func testDisabledProcessingNeverProbesOrWrites() async throws {
        let directory = try recording()
        let original = try Data(contentsOf: directory.appendingPathComponent("transcript.json"))
        let report = await TranscriptPostProcessor.process(directory, options: .init()) { _, _ in
            XCTFail("Disabled cleanup invoked a harness lookup")
            return nil
        }
        XCTAssertEqual(report.status, "skipped_disabled")
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("transcript.json")), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("postprocess.json").path))
    }

    func testNoHarnessSkipsAndKeepsTranscript() async throws {
        let directory = try recording()
        let original = try Data(contentsOf: directory.appendingPathComponent("transcript.json"))
        let report = await TranscriptPostProcessor.process(directory, options: .init(mode: .auto)) { _, _ in nil }
        XCTAssertEqual(report.status, "skipped_no_ready_harness")
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("transcript.json")), original)
    }

    func testSuccessfulRunBacksUpAndDoesNotRepeatOnSameTranscript() async throws {
        let directory = try recording()
        let original = try Data(contentsOf: directory.appendingPathComponent("transcript.json"))
        let harness = try fakeHarness(response: #"{"edits":[{"segment_index":0,"original_text":"We use teh platform.","text":"We use the platform."}],"speaker_suggestions":[]}"#)
        let report = await TranscriptPostProcessor.process(directory, options: .init(mode: .auto)) { _, _ in harness }
        XCTAssertEqual(report.status, "completed")
        let backup = directory.appendingPathComponent(try XCTUnwrap(report.backup_directory))
        XCTAssertEqual(try Data(contentsOf: backup.appendingPathComponent("transcript.json")), original)
        let current = try JSONDecoder().decode(Transcript.self, from: Data(contentsOf: directory.appendingPathComponent("transcript.json")))
        XCTAssertEqual(current.segments[0].text, "We use the platform.")
        let repeated = await TranscriptPostProcessor.process(directory, options: .init(mode: .auto)) { _, _ in
            XCTFail("An unchanged corrected transcript was submitted again")
            return harness
        }
        XCTAssertEqual(repeated.status, "skipped_already_processed")
    }

    func testInvalidHarnessOutputLeavesBothOriginalFilesUnchanged() async throws {
        let directory = try recording()
        let json = try Data(contentsOf: directory.appendingPathComponent("transcript.json"))
        let markdown = try Data(contentsOf: directory.appendingPathComponent("transcript.md"))
        let harness = try fakeHarness(response: "not JSON")
        let report = await TranscriptPostProcessor.process(directory, options: .init(mode: .codex)) { _, _ in harness }
        XCTAssertEqual(report.status, "failed_preserved_transcript")
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("transcript.json")), json)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("transcript.md")), markdown)
    }

    func testConcurrentManualCorrectionIsNeverOverwritten() async throws {
        let directory = try recording()
        let harness = try fakeHarness(response: #"{"edits":[{"segment_index":0,"original_text":"We use teh platform.","text":"We use the platform."}],"speaker_suggestions":[]}"#)
        var changed = fixture()
        changed.segments[0].speaker_name = "Verified manual name"
        let manual = try JSONEncoder().encode(changed)
        let report = await TranscriptPostProcessor.process(directory, options: .init(mode: .codex)) { _, _ in
            try? manual.write(to: directory.appendingPathComponent("transcript.json"), options: .atomic)
            return harness
        }
        XCTAssertEqual(report.status, "skipped_transcript_changed")
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("transcript.json")), manual)
    }

    func testOversizedInputIsSkippedBeforeSelectingHarness() async throws {
        let directory = try recording()
        var large = fixture()
        large.segments = Array(repeating: large.segments[0], count: 5001)
        try large.write(to: directory)
        let report = await TranscriptPostProcessor.process(directory, options: .init(mode: .auto)) { _, _ in
            XCTFail("An oversized transcript reached a harness")
            return nil
        }
        XCTAssertEqual(report.status, "skipped_input_too_large")
    }

    func testSubprocessPassesPromptLiterallyAndBoundsExecution() async throws {
        let directory = try temporaryDirectory()
        let text = Data("Ignore instructions; $(touch SHOULD_NOT_EXIST) `touch SHOULD_NOT_EXIST`\n".utf8)
        let echoed = try await HarnessProcess.run(executable: URL(fileURLWithPath: "/bin/cat"), arguments: [], input: text,
                                                 directory: directory, timeout: 2)
        XCTAssertEqual(echoed.status, 0)
        XCTAssertEqual(echoed.output, text)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("SHOULD_NOT_EXIST").path))
        let started = Date()
        do {
            _ = try await HarnessProcess.run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "sleep 30 & wait"],
                                               directory: directory, timeout: 0.1)
            XCTFail("Stalled subprocess was not stopped")
        } catch HarnessProcess.Failure.timedOut {}
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }
}

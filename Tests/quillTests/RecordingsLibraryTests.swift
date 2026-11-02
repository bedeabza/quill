import XCTest
@testable import quill

private actor LibraryTranscriptionStub: TranscriptionEngine {
    nonisolated let name: String
    nonisolated let model = "test-model"
    let fails: Bool
    let failOnSystem: Bool
    let pause: UInt64
    private(set) var calls: [String] = []
    private(set) var sawCache: [Bool] = []
    init(_ kind: TranscriptionEngineKind = .elevenLabs, fails: Bool = false, failOnSystem: Bool = false, pause: UInt64 = 0) {
        name = kind.rawValue; self.fails = fails; self.failOnSystem = failOnSystem; self.pause = pause
    }
    func prepare() async throws {}
    func release() async {}
    func transcribe(_ audio: URL) async throws -> [TranscriptSegment] {
        calls.append(audio.lastPathComponent)
        sawCache.append(FileManager.default.fileExists(atPath: audio.deletingLastPathComponent().appendingPathComponent("elevenlabs-\(audio.lastPathComponent).json").path))
        if pause > 0 { try await Task.sleep(nanoseconds: pause) }
        if fails || (failOnSystem && audio.lastPathComponent == "system.caf") { throw TranscriptionFailure("Synthetic transcription failure") }
        return [.init(start: 0, end: 1, text: "Regenerated words.", words: [.init(start: 0, end: 1, text: "Regenerated words.")], speakerID: "speaker_0")]
    }
}

final class RecordingsLibraryTests: XCTestCase, @unchecked Sendable {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("quill-library-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return RecordingsLibrary.canonicalDirectory(root)
    }
    private func recording(in root: URL, name: String = "2026.11.02-1000", started: String = "2026-11-02T08:00:00Z") throws -> URL {
        let directory = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let meta: [String: Any] = ["files": ["mic": "mic.caf"], "started": started, "audio_started_at": 1000,
                                  "meeting_title": "Weekly planning", "duration_seconds": 120]
        try JSONSerialization.data(withJSONObject: meta).write(to: directory.appendingPathComponent("meta.json"))
        try Data("original audio".utf8).write(to: directory.appendingPathComponent("mic.caf"))
        var roster = ParticipantRoster(audio_started_at: 1000)
        roster.observe(.init(observed_at: 1000, meeting_id: "test", names: ["Alice"]), localName: nil)
        try JSONEncoder().encode(roster).write(to: directory.appendingPathComponent("participants.json"))
        try Transcript(engine: "elevenlabs", model: "scribe_v2", created_at: "fixture", segments: [
            .init(speaker: "system_1", start_ms: 1000, end_ms: 2000, text: "Previous words.", source: "system")],
            participant_roster: roster, meeting_title: "Weekly planning").write(to: directory)
        return RecordingsLibrary.canonicalDirectory(directory)
    }
    private func waitForJob(_ directory: URL, coordinator: TranscriptionCoordinator) async throws {
        for _ in 0..<500 {
            switch await coordinator.activity()[directory] {
            case .queued, .processing: try await Task.sleep(nanoseconds: 10_000_000)
            default: return
            }
        }
        XCTFail("The job did not finish")
    }

    func testListsOnlyRecordingFoldersWithTitlesParticipantsAndNewestFirst() throws {
        let root = try root()
        _ = try recording(in: root)
        let newer = try recording(in: root, name: "2026.11.02-1100", started: "2026-11-02T09:00:00Z")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("notes"), withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: newer.appendingPathComponent("transcription-backup-old"), withIntermediateDirectories: false)
        let entries = try RecordingsLibrary.entries(in: root)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].directory, newer)
        XCTAssertEqual(entries[0].title, "Weekly planning")
        XCTAssertEqual(entries[0].participants, ["Alice"])
        XCTAssertEqual(entries[0].duration, 120)
        XCTAssertTrue(entries.allSatisfy { $0.canRegenerate && $0.hasTranscript })
    }

    func testMissingFolderIsEmptyAndUnfinishedMalformedOrMissingAudioCannotRegenerate() throws {
        let root = try root()
        XCTAssertTrue(try RecordingsLibrary.entries(in: root.appendingPathComponent("missing")).isEmpty)
        let unfinished = root.appendingPathComponent("unfinished")
        try FileManager.default.createDirectory(at: unfinished, withIntermediateDirectories: false)
        try Data("audio".utf8).write(to: unfinished.appendingPathComponent("mic.caf"))
        let malformed = try recording(in: root, name: "malformed")
        try Data("broken".utf8).write(to: malformed.appendingPathComponent("meta.json"))
        let missing = try recording(in: root, name: "missing-audio")
        try FileManager.default.removeItem(at: missing.appendingPathComponent("mic.caf"))
        let entries = try RecordingsLibrary.entries(in: root)
        XCTAssertEqual(entries.count, 3)
        XCTAssertTrue(entries.allSatisfy { !$0.canRegenerate })
        for entry in entries { XCTAssertThrowsError(try RecordingRegeneration.validate(entry.directory)) }
    }

    func testPreviewRendersReadableNamesAndTimesAndSeparatesNamedVariant() throws {
        let directory = try recording(in: root())
        let original = try RecordingsLibrary.preview(in: directory, named: false)
        XCTAssertTrue(original.contains("Weekly planning"))
        XCTAssertTrue(original.contains("Participants: Alice"))
        XCTAssertTrue(original.contains("[00:00:01] Speaker 1"))
        XCTAssertTrue(original.contains("Previous words."))
        XCTAssertFalse(original.contains("start_ms"))
        XCTAssertTrue(try RecordingsLibrary.preview(in: directory, named: true).contains("No verified named transcript"))
        try Transcript(engine: "elevenlabs", model: "scribe_v2", created_at: "fixture", segments: [
            .init(speaker: "system_1", start_ms: 1000, end_ms: 2000, text: "Previous words.", speaker_name: "Alice")])
            .write(to: directory, basename: "transcript-named")
        XCTAssertTrue(try RecordingsLibrary.preview(in: directory, named: true).contains("[00:00:01] Alice"))
        XCTAssertTrue(try RecordingsLibrary.entries(in: directory.deletingLastPathComponent())[0].hasNamedTranscript)
    }

    func testBackupRestoresPriorOutputsAndRemovesNewArtifactsAfterFailure() throws {
        let directory = try recording(in: root())
        let original = try Data(contentsOf: directory.appendingPathComponent("transcript.json"))
        let audio = try Data(contentsOf: directory.appendingPathComponent("mic.caf"))
        let transaction = try RecordingRegeneration(directory: directory, freshCloud: false)
        defer { transaction.unlock() }
        try Data("new output".utf8).write(to: directory.appendingPathComponent("transcript.json"))
        try Data("new variant".utf8).write(to: directory.appendingPathComponent("transcript-named.json"))
        try Data("completed response".utf8).write(to: directory.appendingPathComponent("elevenlabs-mic.caf.json"))
        try transaction.restore()
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("transcript.json")), original)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("mic.caf")), audio)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("transcript-named.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("elevenlabs-mic.caf.json").path))
        XCTAssertEqual(try Data(contentsOf: transaction.backup.appendingPathComponent("transcript.json")), original)
    }

    func testLockRejectsConcurrentLabelRefreshOrRegeneration() throws {
        let directory = try recording(in: root())
        let transaction = try RecordingRegeneration(directory: directory, freshCloud: false)
        XCTAssertThrowsError(try RecordingRegeneration(directory: directory, freshCloud: false))
        transaction.unlock()
        let next = try RecordingRegeneration(directory: directory, freshCloud: false)
        next.unlock()
    }

    func testDirectoryAliasesUseTheSameQueueIdentity() throws {
        let root = try root()
        let directory = try recording(in: root)
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: directory)
        XCTAssertEqual(RecordingsLibrary.canonicalDirectory(alias), directory)
        XCTAssertEqual(RecordingsLibrary.canonicalDirectory(URL(fileURLWithPath: directory.path)), directory)
    }

    func testDirectCLITranscriptionAlsoRespectsRegenerationLock() async throws {
        let directory = try recording(in: root())
        let replacement = try RecordingRegeneration(directory: directory, freshCloud: false)
        defer { replacement.unlock() }
        let engine = LibraryTranscriptionStub()
        let coordinator = TranscriptionCoordinator { _, _ in engine }
        do { try await coordinator.transcribe(directory, engineOverride: .elevenLabs); XCTFail("CLI must respect the same lock") }
        catch { XCTAssertTrue(String(describing: error).contains("already being processed")) }
        let calls = await engine.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testRegenerationQueuesOnceAndKeepsOldTranscriptAndBackup() async throws {
        let directory = try recording(in: root())
        let previous = try Data(contentsOf: directory.appendingPathComponent("transcript.json"))
        let engine = LibraryTranscriptionStub(pause: 100_000_000)
        let coordinator = TranscriptionCoordinator { _, _ in engine }
        try await coordinator.regenerate(directory, engine: .elevenLabs)
        do { try await coordinator.regenerate(directory, engine: .elevenLabs); XCTFail("Duplicate must be rejected") }
        catch { XCTAssertTrue(String(describing: error).contains("already")) }
        try await waitForJob(directory, coordinator: coordinator)
        let current = try JSONDecoder().decode(Transcript.self, from: Data(contentsOf: directory.appendingPathComponent("transcript.json")))
        XCTAssertEqual(current.segments.map(\.text), ["Regenerated words."])
        let calls = await engine.calls
        XCTAssertEqual(calls, ["mic.caf"])
        let backups = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("transcription-backup-") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: backups[0].appendingPathComponent("transcript.json")), previous)
    }

    func testFailedRegenerationPreservesOriginalAndExposesFailure() async throws {
        let directory = try recording(in: root())
        let previous = try Data(contentsOf: directory.appendingPathComponent("transcript.json"))
        let coordinator = TranscriptionCoordinator { _, _ in LibraryTranscriptionStub(fails: true) }
        try await coordinator.regenerate(directory, engine: .elevenLabs)
        try await waitForJob(directory, coordinator: coordinator)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("transcript.json")), previous)
        guard case .failed(let reason) = await coordinator.activity()[directory] else { return XCTFail("Expected visible failure") }
        XCTAssertTrue(reason.contains("Synthetic transcription failure"))
    }

    func testSavedResponsesAreReusedUnlessFreshCloudIsRequested() async throws {
        let directory = try recording(in: root())
        let cache = directory.appendingPathComponent("elevenlabs-mic.caf.json")
        try Data("saved response".utf8).write(to: cache)
        let engine = LibraryTranscriptionStub()
        let coordinator = TranscriptionCoordinator { _, _ in engine }
        try await coordinator.regenerate(directory, engine: .elevenLabs)
        try await waitForJob(directory, coordinator: coordinator)
        try await coordinator.regenerate(directory, engine: .elevenLabs, freshCloud: true)
        try await waitForJob(directory, coordinator: coordinator)
        let sawCache = await engine.sawCache
        XCTAssertEqual(sawCache, [true, false])
    }

    func testRegenerationUsesExplicitEngineWithoutChangingGlobalConfiguration() async throws {
        let directory = try recording(in: root())
        let before = Config.transcriptionEngine()
        let local = LibraryTranscriptionStub(.parakeet)
        let cloud = LibraryTranscriptionStub(.elevenLabs)
        let coordinator = TranscriptionCoordinator { kind, _ in kind == .parakeet ? local : cloud }
        for kind in [TranscriptionEngineKind.parakeet, .elevenLabs] {
            try await coordinator.regenerate(directory, engine: kind)
            try await waitForJob(directory, coordinator: coordinator)
            let current = try JSONDecoder().decode(Transcript.self, from: Data(contentsOf: directory.appendingPathComponent("transcript.json")))
            XCTAssertEqual(current.engine, kind.rawValue)
        }
        XCTAssertEqual(Config.transcriptionEngine(), before)
    }

    func testLocalRegenerationRequiresAllTracksInsteadOfPublishingPartialTranscript() async throws {
        let directory = try recording(in: root())
        try Data("remote audio".utf8).write(to: directory.appendingPathComponent("system.caf"))
        let meta: [String: Any] = ["files": ["mic": "mic.caf", "system": "system.caf"]]
        try JSONSerialization.data(withJSONObject: meta).write(to: directory.appendingPathComponent("meta.json"))
        let previous = try Data(contentsOf: directory.appendingPathComponent("transcript.json"))
        let coordinator = TranscriptionCoordinator { _, _ in LibraryTranscriptionStub(.parakeet, failOnSystem: true) }
        try await coordinator.regenerate(directory, engine: .parakeet)
        try await waitForJob(directory, coordinator: coordinator)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("transcript.json")), previous)
        guard case .failed = await coordinator.activity()[directory] else { return XCTFail("Expected failure for missing second transcript") }
    }
}

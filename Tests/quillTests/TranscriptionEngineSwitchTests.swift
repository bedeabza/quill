import XCTest
@testable import quill

private actor StubTranscriptionEngine: TranscriptionEngine {
    nonisolated let name: String
    nonisolated let model = "test-model"
    var prepares = 0
    var releases = 0
    let failing: Bool
    let failOnSystem: Bool
    init(_ kind: TranscriptionEngineKind, failing: Bool = false, failOnSystem: Bool = false) {
        name = kind.rawValue; self.failing = failing; self.failOnSystem = failOnSystem
    }
    func prepare() async throws { prepares += 1 }
    func release() async { releases += 1 }
    func transcribe(_ audio: URL) async throws -> [TranscriptSegment] {
        if failing || (failOnSystem && audio.lastPathComponent == "system.caf") { throw TranscriptionFailure("test inference failure") }
        return [TranscriptSegment(start: 0.5, end: 1, text: name)]
    }
}

final class TranscriptionEngineSwitchTests: XCTestCase, @unchecked Sendable {
    private func session() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("quill-engine-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        try Data(#"{"files":{"mic":"mic.caf","system":"system.caf"},"start_offset_ms":{"mic":100,"system":200}}"#.utf8)
            .write(to: dir.appendingPathComponent("meta.json"))
        for file in ["mic.caf", "system.caf"] { try Data().write(to: dir.appendingPathComponent(file)) }
        return dir
    }

    func testSwitchReleasesPreviousEngineAndPreservesProvenanceAndOffsets() async throws {
        let parakeet = StubTranscriptionEngine(.parakeet), elevenlabs = StubTranscriptionEngine(.elevenLabs)
        let coordinator = TranscriptionCoordinator { kind, _ in kind == .parakeet ? parakeet : elevenlabs }
        let dir = try session()
        defer { try? FileManager.default.removeItem(at: dir) }
        for kind in [TranscriptionEngineKind.parakeet, .elevenLabs, .parakeet] {
            try await coordinator.transcribe(dir, detectSpeakers: false, engineOverride: kind)
            let transcript = try JSONDecoder().decode(Transcript.self, from: Data(contentsOf: dir.appendingPathComponent("transcript.json")))
            XCTAssertEqual(transcript.engine, kind.rawValue)
            XCTAssertEqual(transcript.segments.map(\.text), [kind.rawValue, kind.rawValue])
            XCTAssertEqual(transcript.segments.map(\.start_ms), [600, 700])
        }
        let parakeetPrepares = await parakeet.prepares, elevenlabsReleases = await elevenlabs.releases
        XCTAssertEqual(parakeetPrepares, 2)
        XCTAssertEqual(elevenlabsReleases, 1)
    }

    func testAllTrackFailuresRemainPendingWithoutFallback() async throws {
        let elevenlabs = StubTranscriptionEngine(.elevenLabs, failing: true)
        let coordinator = TranscriptionCoordinator { _, _ in elevenlabs }
        let dir = try session()
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            try await coordinator.transcribe(dir, detectSpeakers: false, engineOverride: .elevenLabs)
            XCTFail("Expected inference failure")
        } catch { XCTAssertTrue(String(describing: error).contains("test inference failure")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("transcript.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("transcript.md").path))
    }

    func testCloudSecondTrackFailureDoesNotPublishPartialTranscript() async throws {
        let engine = StubTranscriptionEngine(.elevenLabs, failOnSystem: true)
        let coordinator = TranscriptionCoordinator { _, _ in engine }
        let dir = try session()
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            try await coordinator.transcribe(dir, detectSpeakers: false, engineOverride: .elevenLabs)
            XCTFail("A failed cloud track must leave the session pending")
        } catch { XCTAssertTrue(String(describing: error).contains("test inference failure")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("transcript.json").path))
    }
}

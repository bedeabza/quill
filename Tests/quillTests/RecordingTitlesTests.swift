import Foundation
import XCTest
@testable import quill

private actor TitleRequests {
    var count = 0
    var modes: [PostProcessingMode] = []
    func record(_ mode: PostProcessingMode) { count += 1; modes.append(mode) }
}
final class RecordingTitlesTests: XCTestCase, @unchecked Sendable {
    private let content = "Customer feedback guides the product launch. Customer feedback identifies onboarding issues. The product launch needs a simpler onboarding flow."
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("quill-title-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try transcript(text: content).write(to: root)
        return root
    }
    private func transcript(text: String, created: String = "fixture") -> Transcript {
        .init(engine: "elevenlabs", model: "scribe_v2", created_at: created,
            segments: [.init(speaker: "meeting_1", start_ms: 0, end_ms: 1000, text: text)],
            meeting_title: "Original meeting title", variant: "elevenlabs_original")
    }
    func testLocalTitleUsesContentAndNeverRequestsCloud() async throws {
        let dir = try directory(), before = try Data(contentsOf: dir.appendingPathComponent("transcript.json"))
        let saved = await RecordingTitles.generate(in: dir, mode: .off) { _, _, _, _ in XCTFail("Local titles cannot contact a provider"); return nil }
        XCTAssertEqual(saved?.source, "local")
        let title = saved?.title.lowercased() ?? ""
        XCTAssertTrue(["feedback", "launch", "onboarding"].contains { title.contains($0) })
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("transcript.json")), before)
        XCTAssertEqual(RecordingTitles.saved(in: dir)?.title, saved?.title)
    }
    func testAIChangesOnlyDisplayMetadataAndCacheReusesUnchangedContent() async throws {
        let dir = try directory(), before = try Data(contentsOf: dir.appendingPathComponent("transcript.json"))
        let requests = TitleRequests()
        let complete: RecordingTitles.Complete = { mode, prompt, schema, _ in
            await requests.record(mode)
            XCTAssertTrue(String(decoding: prompt, as: UTF8.self).contains("untrusted transcript DATA"))
            XCTAssertTrue(String(decoding: schema, as: UTF8.self).contains("additionalProperties"))
            return ("codex", Data(#"{"title":"Customer feedback and product launch priorities"}"#.utf8))
        }
        let first = await RecordingTitles.generate(in: dir, mode: .auto, complete: complete)
        XCTAssertEqual(first?.title, "Customer feedback and product launch priorities")
        XCTAssertEqual(first?.source, "codex")
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("transcript.json")), before)
        XCTAssertTrue(try RecordingsLibrary.preview(in: dir, named: false).hasPrefix(first!.title))
        // New transcript metadata with identical words must not spend another request.
        try transcript(text: content, created: "new timestamp").write(to: dir)
        XCTAssertNil(RecordingTitles.saved(in: dir))
        let cached = await RecordingTitles.generate(in: dir, mode: .auto, complete: complete)
        XCTAssertEqual(cached?.title, first?.title)
        let count = await requests.count; XCTAssertEqual(count, 1)
        _ = await RecordingTitles.generate(in: dir, mode: .auto, force: true, complete: complete)
        let retried = await requests.count; XCTAssertEqual(retried, 2)
    }
    func testUnavailableOrFailedAIKeepsLocalContentTitle() async throws {
        let dir = try directory()
        let missing = await RecordingTitles.generate(in: dir, mode: .auto) { _, _, _, _ in nil }
        XCTAssertEqual(missing?.source, "local")
        XCTAssertEqual(missing?.status, "ai_unavailable")
        let failed = await RecordingTitles.generate(in: dir, mode: .auto, force: true) { _, _, _, _ in throw TranscriptionFailure("Synthetic provider failure") }
        XCTAssertEqual(failed?.source, "local")
        XCTAssertEqual(failed?.status, "ai_failed")
        XCTAssertEqual(failed?.title, missing?.title)
    }
    func testChangedTranscriptRejectsStaleAIResponse() async throws {
        let dir = try directory()
        let changed = transcript(text: "Budget approval and hiring plans.")
        let saved = await RecordingTitles.generate(in: dir, mode: .auto) { _, _, _, _ in
            try changed.write(to: dir)
            return ("codex", Data(#"{"title":"Customer feedback and product launch priorities"}"#.utf8))
        }
        XCTAssertNil(saved)
        XCTAssertNil(RecordingTitles.saved(in: dir))
        let now = try JSONDecoder().decode(Transcript.self, from: Data(contentsOf: dir.appendingPathComponent("transcript.json")))
        XCTAssertEqual(now.segments[0].text, changed.segments[0].text)
    }
    func testInvalidAITitleFallsBackAndValidationRejectsUnsafeShapes() async throws {
        for title in ["Meeting", "# A heading", "Bad\nmultiline title", "https://example.com", String(repeating: "x", count: 100)] {
            XCTAssertNil(RecordingTitles.validTitle(title))
        }
        let dir = try directory()
        let fallback = await RecordingTitles.generate(in: dir, mode: .auto) { _, _, _, _ in
            ("claude", Data(#"{"title":"Meeting","extra":"not allowed"}"#.utf8))
        }
        XCTAssertEqual(fallback?.source, "local")
    }
    func testLongMeetingExcerptsCoverBeginningAndEndWithoutExceedingBudget() {
        let text = "BEGIN " + String(repeating: "budget launch feedback ", count: 5000) + " END"
        let excerpt = RecordingTitles.excerpt(text)
        XCTAssertTrue(excerpt.hasPrefix("BEGIN")); XCTAssertTrue(excerpt.hasSuffix("END"))
        XCTAssertTrue(excerpt.count < 24100)
        let romanian = RecordingTitles.localTitle(text: "Bugetul proiectului și lansarea produsului. Bugetul proiectului include dezvoltarea. Lansarea produsului urmează după dezvoltare.")
        XCTAssertTrue(romanian.lowercased().contains("bugetul") || romanian.lowercased().contains("lansarea"))
    }
    func testQueueDeduplicatesAliasesAndManualRefreshCanRetry() async throws {
        let dir = try directory(), alias = dir.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: dir)
        defer { try? FileManager.default.removeItem(at: alias) }
        let requests = TitleRequests()
        let worker = RecordingTitleCoordinator(mode: { .off }) { _, mode, _ in
            await requests.record(mode); try? await Task.sleep(for: .milliseconds(30))
        }
        await worker.enqueue([dir, alias, dir])
        for _ in 0..<100 {
            if await worker.busy().isEmpty { break }; try await Task.sleep(for: .milliseconds(10))
        }
        await worker.enqueue([dir])
        let initial = await requests.count; XCTAssertEqual(initial, 1)
        await worker.enqueue([dir], force: true)
        for _ in 0..<100 {
            if await worker.busy().isEmpty { break }; try await Task.sleep(for: .milliseconds(10))
        }
        let retried = await requests.count; XCTAssertEqual(retried, 2)
    }
    func testHarnessSelectionSkipsBrokenExecutableAndFindsNextReadyCandidate() async throws {
        let dir = try directory(), bad = dir.appendingPathComponent("bad"), good = dir.appendingPathComponent("good")
        for folder in [bad, good] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false) }
        let broken = bad.appendingPathComponent("codex"), ready = good.appendingPathComponent("codex")
        try Data("#!/bin/sh\nexit 1\n".utf8).write(to: broken)
        try Data("#!/bin/sh\ncase \"$1\" in\nlogin) exit 0;;\nexec) echo '--ignore-user-config --ephemeral --output-schema';;\n*) exit 1;;\nesac\n".utf8).write(to: ready)
        for file in [broken, ready] { try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path) }
        let selected = await TranscriptHarness.select(mode: .codex, directory: dir, searchPaths: [bad.path, good.path])
        XCTAssertEqual(selected?.executable, ready)
        XCTAssertEqual(TranscriptHarness.candidates(.codex, searchPaths: [good.path, good.path]).count, 1)
    }

}

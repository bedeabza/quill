import CryptoKit
import Darwin
import XCTest
@testable import quill

private actor S3TestSink {
    var keys: [String] = []
    var bodies: [Data] = []
    var failure: Int?
    init(failure: Int? = nil) { self.failure = failure }
    func put(_ key: String, _ body: Data) throws {
        keys.append(key); bodies.append(body)
        if let failure { try S3Client.validate(status: failure) }
    }
    func allow() { failure = nil }
}

private actor S3TestGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false
    private(set) var entered = false
    private(set) var cancelled = false
    func pause() async {
        entered = true
        if !opened { await withCheckedContinuation { continuation = $0 } }
    }
    func release() { opened = true; continuation?.resume(); continuation = nil }
    func cancellableRequest() async throws {
        entered = true
        do { try await Task.sleep(for: .seconds(30)) }
        catch { cancelled = true; throw error }
    }
}
private struct S3TranscriptionStub: TranscriptionEngine {
    let name = "parakeet"
    let model = "fixture"
    var fails = false
    func prepare() async throws {}
    func release() async {}
    func transcribe(_ audio: URL) async throws -> [TranscriptSegment] {
        if fails { throw TranscriptionFailure("Synthetic ASR failure") }
        return [.init(start: 0, end: 1, text: "New completed transcription.")]
    }
}
private final class S3TestSettings: @unchecked Sendable {
    private let lock = NSLock()
    private var value: S3Configuration
    private var secrets: [String: String] = [:]
    init(_ value: S3Configuration) { self.value = value }
    func config() -> S3Configuration { lock.withLock { value } }
    func set(_ config: S3Configuration) { lock.withLock { value = config } }
    func read(_ key: String) -> String? { lock.withLock { secrets[key] } }
    func save(_ secret: String, _ key: String) { lock.withLock { secrets[key] = secret } }
    func remove(_ key: String) { lock.withLock { _ = secrets.removeValue(forKey: key) } }
}

final class S3UploadTests: XCTestCase, @unchecked Sendable {
    private func config() -> S3Configuration {
        S3Configuration(enabled: true, bucket: "test-bucket", region: "eu-central-1", prefix: "transcripts/", accessKeyID: "AKIAIOSFODNN7EXAMPLE")
    }
    private func fixture(_ name: String = "2026.11.20-1000") throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("quill-s3-" + UUID().uuidString)
        let dir = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let meta: [String: Any] = ["started": "2026-11-20T08:00:00Z", "ended": "2026-11-20T08:01:00Z", "duration_seconds": 60,
            "audio_started_at": 1795161600, "meeting_title": "Ședință proiect: buget & plan", "local_speaker_name": "Jamie Morgan",
            "files": ["mic": "mic.caf"], "start_offset_ms": ["mic": 100], "microphone_gaps": [["start": 20, "end": 26]], "shared_microphone": false]
        try JSONSerialization.data(withJSONObject: meta).write(to: dir.appendingPathComponent("meta.json"))
        try AudioTestSupport.write(dir.appendingPathComponent("mic.caf"))
        try transcript().write(to: dir)
        return RecordingsLibrary.canonicalDirectory(dir)
    }
    private func transcript(_ text: String = "Decidem bugetul pentru lansare.") -> Transcript {
        Transcript(engine: "elevenlabs", model: "scribe_v2", created_at: "2026-11-20T08:02:00Z",
            segments: [.init(speaker: "meeting_1", start_ms: 1234, end_ms: 5000, text: text, source: "meeting", speaker_name: "Jamie Morgan", attribution: "manual")],
            schema_version: 2, variant: "elevenlabs_original")
    }
    private func uploader(_ settings: S3TestSettings, _ sink: S3TestSink) -> S3UploadCoordinator {
        S3UploadCoordinator(configuration: { settings.config() }, secret: { _ in String(repeating: "s", count: 40) },
            put: { _, key, body, _ in try await sink.put(key, body) }, title: { _ in }, automaticRetry: false)
    }

    private func waitForGate(_ gate: S3TestGate) async throws {
        for _ in 0..<200 {
            if await gate.entered { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Upload did not reach the controlled test pause")
    }

    @MainActor func testFreshSettingsRequireAnExplicitDestinationBeforeSavingSecrets() async throws {
        let dir = try fixture(), configURL = dir.appendingPathComponent("config.json")
        try Data(#"{"other_setting":"preserved"}"#.utf8).write(to: configURL)
        let before = try Data(contentsOf: configURL)
        let settings = S3TestSettings(config())
        let model = S3SettingsModel(configURL: configURL, readSecret: { settings.read($0) },
            saveSecret: { settings.save($0, $1) }, deleteSecret: { settings.remove($0) })
        XCTAssertFalse(model.configuration.enabled)
        XCTAssertEqual(model.configuration.bucket, "")
        XCTAssertEqual(model.configuration.region, "")
        XCTAssertEqual(model.configuration.prefix, "")
        model.configuration.enabled = true
        model.configuration.accessKeyID = config().accessKeyID
        let saved = await model.save(secret: String(repeating: "s", count: 40))
        XCTAssertFalse(saved)
        XCTAssertNil(settings.read(config().accessKeyID))
        XCTAssertEqual(try Data(contentsOf: configURL), before)
        try Config.setS3(config(), at: configURL)
        XCTAssertEqual(Config.s3(at: configURL), config(), "Explicitly saved destinations survive reload")
    }

    func testIncompleteDestinationNeverReachesManualOrAutomaticTransport() async throws {
        let dir = try fixture(), sink = S3TestSink()
        for field in [\S3Configuration.bucket, \S3Configuration.region, \S3Configuration.prefix] {
            var incomplete = config(); incomplete[keyPath: field] = ""
            let uploads = uploader(S3TestSettings(incomplete), sink)
            do { try await uploads.syncNow(dir); XCTFail("Incomplete manual destination was accepted") }
            catch {}
            await uploads.enqueue(dir)
            await uploads.waitUntilIdle()
        }
        let keys = await sink.keys
        XCTAssertTrue(keys.isEmpty)
    }

    func testBlockedDiscussionNeverAutoUploadsAndBlockSurvivesRestart() async throws {
        let dir = try fixture(), settings = S3TestSettings(config()), sink = S3TestSink()
        let uploads = uploader(settings, sink)
        try await uploads.setBlocked(true, in: dir)
        await uploads.enqueue(dir); await uploads.waitUntilIdle()
        try transcript("Saved correction must also stay local.").write(to: dir)
        let restarted = uploader(settings, sink)
        await restarted.enqueue(dir)
        await restarted.resumePending(root: dir.deletingLastPathComponent())
        await restarted.waitUntilIdle()
        let keys = await sink.keys
        XCTAssertTrue(keys.isEmpty)
        XCTAssertNil(S3UploadRecord.read(in: dir))
        XCTAssertTrue(S3SyncPreference.read(in: dir).blocked)
        XCTAssertTrue(try XCTUnwrap(RecordingsLibrary.entries(in: dir.deletingLastPathComponent()).first).s3Blocked)
    }

    func testSyncNowForcesFreshCopyAndExplicitlyUnblocks() async throws {
        let dir = try fixture(), settings = S3TestSettings(config()), sink = S3TestSink()
        let uploads = uploader(settings, sink)
        await uploads.enqueue(dir); await uploads.waitUntilIdle()
        let original = try XCTUnwrap(S3UploadRecord.read(in: dir))
        try await uploads.syncNow(dir); await uploads.waitUntilIdle()
        let forced = try XCTUnwrap(S3UploadRecord.read(in: dir))
        XCTAssertNotEqual(forced.key, original.key, "Force must bypass unchanged-content deduplication")
        XCTAssertEqual(forced.previousKeys, [original.location])
        try await uploads.setBlocked(true, in: dir)
        XCTAssertEqual(S3UploadRecord.read(in: dir)?.key, forced.key, "Blocking keeps the last receipt")
        try await uploads.syncNow(dir); await uploads.waitUntilIdle()
        XCTAssertFalse(S3SyncPreference.read(in: dir).blocked)
        let keys = await sink.keys
        XCTAssertEqual(keys.count, 3)
        XCTAssertEqual(Set(keys).count, 3)
        XCTAssertEqual(S3UploadRecord.read(in: dir)?.previousKeys, [original.location, forced.location])
    }

    func testManualSyncAndItsRetryRunWithAutomaticSyncOff() async throws {
        let dir = try fixture(), sink = S3TestSink(failure: 503)
        var config = config(); config.enabled = false
        let settings = S3TestSettings(config), uploads = uploader(settings, sink)
        await uploads.enqueue(dir)
        XCTAssertNil(S3UploadRecord.read(in: dir))
        try await uploads.syncNow(dir); await uploads.waitUntilIdle()
        XCTAssertEqual(S3UploadRecord.read(in: dir)?.manualRequest, true)
        await sink.allow()
        let restarted = uploader(settings, sink)
        await restarted.resumePending(root: dir.deletingLastPathComponent()); await restarted.waitUntilIdle()
        let keys = await sink.keys
        XCTAssertEqual(keys.count, 2)
        XCTAssertEqual(keys[0], keys[1], "Retry uses the same immutable snapshot")
        XCTAssertEqual(S3UploadRecord.read(in: dir)?.phase, .uploaded)
        XCTAssertFalse(settings.config().enabled, "One discussion must not enable automatic syncing globally")
        try transcript("A later correction still needs a manual request.").write(to: dir)
        await uploads.enqueue(dir); await uploads.waitUntilIdle()
        let after = await sink.keys
        XCTAssertEqual(after.count, 2)
    }

    func testBlockRevokesFailedRetryEvenAfterAllowingFutureAutomaticSync() async throws {
        let dir = try fixture(), settings = S3TestSettings(config()), sink = S3TestSink(failure: 503)
        let uploads = uploader(settings, sink)
        await uploads.enqueue(dir); await uploads.waitUntilIdle()
        try await uploads.setBlocked(true, in: dir)
        await sink.allow()
        let restarted = uploader(settings, sink)
        await restarted.resumePending(root: dir.deletingLastPathComponent()); await restarted.waitUntilIdle()
        try await restarted.setBlocked(false, in: dir)
        await restarted.resumePending(root: dir.deletingLastPathComponent()); await restarted.waitUntilIdle()
        let stopped = await sink.keys
        XCTAssertEqual(stopped.count, 1, "Allowing future sync must not revive a previously revoked request")
        await restarted.enqueue(dir); await restarted.waitUntilIdle()
        let updated = await sink.keys
        XCTAssertEqual(updated.count, 2)
        XCTAssertNotEqual(updated[0], updated[1])
    }

    func testBlockStopsPreparationQueuedWorkAndRerun() async throws {
        let first = try fixture(), second = try fixture("2026.11.20-1100"), settings = S3TestSettings(config())
        let sink = S3TestSink(), gate = S3TestGate()
        let uploads = S3UploadCoordinator(configuration: { settings.config() }, secret: { _ in "fixture" },
            put: { _, key, body, _ in try await sink.put(key, body) }, title: { _ in await gate.pause() }, automaticRetry: false)
        await uploads.enqueue(first)
        try await waitForGate(gate)
        await uploads.enqueue(first) // pending correction while active
        await uploads.enqueue(second)
        try await uploads.setBlocked(true, in: first)
        try await uploads.setBlocked(true, in: second)
        await gate.release(); await uploads.waitUntilIdle()
        let keys = await sink.keys, busy = await uploads.busy()
        XCTAssertTrue(keys.isEmpty)
        XCTAssertTrue(busy.isEmpty)
    }

    func testBlockCancelsActiveRequestAndStopsRetries() async throws {
        let dir = try fixture(), settings = S3TestSettings(config()), gate = S3TestGate()
        let uploads = S3UploadCoordinator(configuration: { settings.config() }, secret: { _ in "fixture" },
            put: { _, _, _, _ in try await gate.cancellableRequest() }, title: { _ in })
        await uploads.enqueue(dir)
        try await waitForGate(gate)
        try await uploads.setBlocked(true, in: dir)
        await uploads.waitUntilIdle()
        let cancelled = await gate.cancelled
        XCTAssertTrue(cancelled)
        XCTAssertTrue(S3SyncPreference.read(in: dir).blocked)
        let record = try XCTUnwrap(S3UploadRecord.read(in: dir))
        XCTAssertEqual(record.phase, .failed)
        XCTAssertFalse(record.retryable)
        XCTAssertTrue(record.message?.contains("may have completed") == true)
        await uploads.resumePending(root: dir.deletingLastPathComponent())
        let busy = await uploads.busy()
        XCTAssertTrue(busy.isEmpty)
    }

    func testAnotherProcessCanRevokePreparationWithoutRevivingItOnUnblock() async throws {
        let dir = try fixture(), settings = S3TestSettings(config()), sink = S3TestSink(), gate = S3TestGate()
        let active = S3UploadCoordinator(configuration: { settings.config() }, secret: { _ in "fixture" },
            put: { _, key, body, _ in try await sink.put(key, body) }, title: { _ in await gate.pause() }, automaticRetry: false)
        await active.enqueue(dir)
        try await waitForGate(gate)
        let other = uploader(settings, sink)
        try await other.setBlocked(true, in: dir)
        try await other.setBlocked(false, in: dir)
        await gate.release(); await active.waitUntilIdle()
        let keys = await sink.keys
        XCTAssertTrue(keys.isEmpty, "An older request must not inherit new permission")
        try await other.syncNow(dir); await other.waitUntilIdle()
        let sent = await sink.keys
        XCTAssertEqual(sent.count, 1)
    }

    func testUnreadablePreferenceBlocksAndInvalidManualSetupDoesNotUnblock() async throws {
        let dir = try fixture(), sink = S3TestSink()
        try Data("broken json".utf8).write(to: dir.appendingPathComponent(S3SyncPreference.filename))
        var invalid = config(); invalid.accessKeyID = ""
        let settings = S3TestSettings(invalid), uploads = uploader(settings, sink)
        await uploads.enqueue(dir); await uploads.waitUntilIdle()
        do { try await uploads.syncNow(dir); XCTFail("Invalid configuration must fail before unblocking") }
        catch { }
        XCTAssertTrue(S3SyncPreference.read(in: dir).blocked)
        let keys = await sink.keys
        XCTAssertTrue(keys.isEmpty)
        settings.set(config())
        try await uploads.syncNow(dir); await uploads.waitUntilIdle()
        XCTAssertFalse(S3SyncPreference.read(in: dir).blocked)
        XCTAssertEqual(S3UploadRecord.read(in: dir)?.phase, .uploaded)
    }

    @MainActor func testRecordingControlsShowBlockAndCanForceSyncWithoutGlobalEnable() async throws {
        let dir = try fixture(), sink = S3TestSink()
        var disabled = config(); disabled.enabled = false
        let uploads = uploader(S3TestSettings(disabled), sink)
        let model = RecordingsModel(root: dir.deletingLastPathComponent(), transcription: TranscriptionCoordinator(),
            titles: RecordingTitleCoordinator(mode: { .off }, generate: { _, _, _ in }), uploads: uploads)
        model.refresh()
        for _ in 0..<200 {
            if model.selectedEntry != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let entry = try XCTUnwrap(model.selectedEntry)
        model.setS3Blocked(true, for: entry)
        for _ in 0..<200 {
            if model.selectedEntry?.s3Blocked == true { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let blocked = try XCTUnwrap(model.selectedEntry)
        XCTAssertTrue(blocked.s3Blocked)
        XCTAssertTrue(model.canSyncToS3(blocked))
        model.uploadToS3(blocked)
        for _ in 0..<200 {
            if model.s3Actions.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        await uploads.waitUntilIdle()
        XCTAssertEqual(S3UploadRecord.read(in: dir)?.phase, .uploaded)
        XCTAssertFalse(S3SyncPreference.read(in: dir).blocked)
        let keys = await sink.keys
        XCTAssertEqual(keys.count, 1)
    }

    func testAWSReferenceSignatureAndUnicodePathEncoding() throws {
        // AWS published GET /test.txt, range 0-9 example, using its public example credential.
        let hash = S3Signing.hash(Data())
        let headers = ["host": "examplebucket.s3.amazonaws.com", "range": "bytes=0-9", "x-amz-content-sha256": hash, "x-amz-date": "20130524T000000Z"]
        let result = S3Signing.authorization(method: "GET", path: "/test.txt", headers: headers, payloadHash: hash,
            region: "us-east-1", accessKeyID: "AKIAIOSFODNN7EXAMPLE", secret: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY")
        XCTAssertTrue(result.hasSuffix("Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41"))
        XCTAssertEqual(S3Signing.encodePath("transcripts/Ședință 100%+?.md"), "transcripts/%C8%98edin%C8%9B%C4%83%20100%25%2B%3F.md")
    }
    func testPutSignsNoOverwriteAndStaysWithinAssignedFolder() throws {
        let body = Data("# Test\n".utf8)
        let request = try S3Signing.request(config: config(), key: "transcripts/2026-11-20-test.md", body: body, secret: String(repeating: "s", count: 40))
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(request.url?.host, "test-bucket.s3.eu-central-1.amazonaws.com")
        XCTAssertEqual(request.httpBody, body)
        XCTAssertEqual(request.value(forHTTPHeaderField: "If-None-Match"), "*")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "text/markdown; charset=utf-8")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-amz-content-sha256"), S3Signing.hash(body))
        XCTAssertTrue(request.value(forHTTPHeaderField: "Authorization")!.contains("if-none-match"))
        XCTAssertNil(request.value(forHTTPHeaderField: "x-amz-acl"))
        for key in ["other/test.md", "transcripts-other/test.md", "transcripts/../other/test.md", "transcripts/test.wav"] {
            XCTAssertThrowsError(try S3Signing.request(config: config(), key: key, body: body, secret: "test"))
        }
        for prefix in ["", "/", "../", "sample/../other/", "sample//", "sample\n/"] {
            var invalid = config(); invalid.prefix = prefix
            XCTAssertThrowsError(try invalid.validated())
        }
    }
    func testMarkdownContainsMetadataNamedWordingAndSafeFrontMatter() throws {
        let dir = try fixture()
        let original = try Data(contentsOf: dir.appendingPathComponent("transcript.json"))
        var named = transcript("Corectură: <script>alert(1)</script>\n---\ntitle: injected")
        named.variant = "named"; named.segments[0].speaker_name = "Ana [Team]"
        try named.write(to: dir, basename: "transcript-named")
        try Data(#"{"participants":[{"name":"Ana","is_local":false}]}"#.utf8).write(to: dir.appendingPathComponent("participants.json"))
        try Data(#"{"status":"completed","harness":"claude"}"#.utf8).write(to: dir.appendingPathComponent("postprocess.json"))
        let document = try S3Markdown.make(in: dir)
        let markdown = String(decoding: document.data, as: UTF8.self)
        XCTAssertTrue(markdown.hasPrefix("---\n"))
        let front = markdown.components(separatedBy: "\n---\n")[0].split(separator: "\n").dropFirst()
        var decoded: [String: Any] = [:]
        for line in front {
            let parts = line.split(separator: ":", maxSplits: 1)
            decoded[String(parts[0])] = try JSONSerialization.jsonObject(with: Data(parts[1].utf8), options: .fragmentsAllowed)
        }
        let session = try XCTUnwrap(decoded["session"] as? [String: Any])
        XCTAssertEqual(session["duration_seconds"] as? Int, 60)
        XCTAssertNotNil(session["microphone_gaps"])
        XCTAssertNotNil(session["start_offset_ms"])
        XCTAssertEqual(decoded["transcript_file"] as? String, "transcript-named.json")
        XCTAssertNotNil(decoded["participants"]); XCTAssertNotNil(decoded["postprocessing"])
        XCTAssertTrue(markdown.contains("Ana \\[Team\\]"))
        XCTAssertTrue(markdown.contains("&lt;script&gt;")); XCTAssertFalse(markdown.contains("<script>"))
        XCTAssertTrue(markdown.contains("[00:00:01]")); XCTAssertFalse(markdown.contains("Decidem bugetul"))
        XCTAssertTrue(document.stem.hasPrefix("2026-11-20-080000-sedinta-proiect"))
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("transcript.json")), original)
    }
    func testSuccessPersistsReceiptDeduplicatesAndCorrectionsUseNewKey() async throws {
        let dir = try fixture(), settings = S3TestSettings(config()), sink = S3TestSink()
        let uploads = uploader(settings, sink)
        await uploads.enqueue(dir); await uploads.waitUntilIdle()
        let first = try XCTUnwrap(S3UploadRecord.read(in: dir))
        XCTAssertEqual(first.phase, .uploaded); XCTAssertNotNil(first.uploadedAt)
        XCTAssertTrue(first.current(in: dir))
        await uploads.enqueue(dir); await uploads.waitUntilIdle()
        let once = await sink.keys; XCTAssertEqual(once.count, 1)
        try transcript("A new saved correction.").write(to: dir, basename: "transcript-named")
        XCTAssertFalse(first.current(in: dir))
        await uploads.enqueue(dir); await uploads.waitUntilIdle()
        let keys = await sink.keys; XCTAssertEqual(keys.count, 2); XCTAssertNotEqual(keys[0], keys[1])
        XCTAssertTrue(keys.allSatisfy { $0.hasPrefix("transcripts/2026-11-20-") && $0.hasSuffix(".md") })
        let record = try XCTUnwrap(S3UploadRecord.read(in: dir))
        XCTAssertEqual(record.previousKeys, [first.location]); XCTAssertTrue(record.current(in: dir))
    }
    func testTransientFailureSurvivesRestartWithIdenticalKeyAndSnapshot() async throws {
        let dir = try fixture(), settings = S3TestSettings(config()), sink = S3TestSink(failure: 503)
        let first = uploader(settings, sink)
        await first.enqueue(dir); await first.waitUntilIdle()
        let failed = try XCTUnwrap(S3UploadRecord.read(in: dir)); XCTAssertEqual(failed.phase, .failed); XCTAssertTrue(failed.retryable)
        let originalBody = try Data(contentsOf: dir.appendingPathComponent(S3UploadRecord.payloadName))
        try transcript("Changed after failed network request.").write(to: dir)
        await sink.allow()
        let restarted = uploader(settings, sink)
        await restarted.resumePending(root: dir.deletingLastPathComponent()); await restarted.waitUntilIdle()
        let keys = await sink.keys, bodies = await sink.bodies
        XCTAssertEqual(keys.count, 2); XCTAssertEqual(keys[0], keys[1]); XCTAssertEqual(bodies[0], bodies[1]); XCTAssertEqual(bodies[1], originalBody)
        let done = try XCTUnwrap(S3UploadRecord.read(in: dir)); XCTAssertEqual(done.phase, .uploaded); XCTAssertFalse(done.current(in: dir))
    }
    func testCollisionIsNotSuccessAndManualRetryUsesAnotherKey() async throws {
        let dir = try fixture(), settings = S3TestSettings(config()), sink = S3TestSink(failure: 412)
        let uploads = uploader(settings, sink)
        await uploads.enqueue(dir); await uploads.waitUntilIdle()
        let failed = try XCTUnwrap(S3UploadRecord.read(in: dir))
        XCTAssertEqual(failed.phase, .failed); XCTAssertFalse(failed.retryable); XCTAssertNil(failed.uploadedAt)
        XCTAssertTrue(failed.message!.contains("Nothing was overwritten"))
        await sink.allow(); await uploads.enqueue(dir); await uploads.waitUntilIdle()
        let keys = await sink.keys; XCTAssertEqual(keys.count, 2); XCTAssertNotEqual(keys[0], keys[1])
        XCTAssertEqual(S3UploadRecord.read(in: dir)?.phase, .uploaded)
    }
    func testDisabledOrMissingSecretNeverSendsAndResumeDoesNotUploadHistory() async throws {
        let dir = try fixture(), sink = S3TestSink()
        var disabled = config(); disabled.enabled = false
        let settings = S3TestSettings(disabled), uploads = uploader(settings, sink)
        await uploads.enqueue(dir); await uploads.waitUntilIdle(); XCTAssertNil(S3UploadRecord.read(in: dir))
        settings.set(config())
        await uploads.resumePending(root: dir.deletingLastPathComponent()); await uploads.waitUntilIdle()
        let keys = await sink.keys; XCTAssertTrue(keys.isEmpty)
        let noKey = S3UploadCoordinator(configuration: { settings.config() }, secret: { _ in nil },
            put: { _, _, _, _ in XCTFail("Must not send without credentials") }, title: { _ in }, automaticRetry: false)
        await noKey.enqueue(dir); await noKey.waitUntilIdle()
        XCTAssertEqual(S3UploadRecord.read(in: dir)?.phase, .failed)
        XCTAssertTrue(S3UploadRecord.read(in: dir)?.message?.contains("secret is missing") == true)
    }
    func testChangedDestinationNeverSilentlyReroutesPendingTranscript() async throws {
        let dir = try fixture(), sink = S3TestSink(failure: 503), settings = S3TestSettings(config())
        let uploads = uploader(settings, sink)
        await uploads.enqueue(dir); await uploads.waitUntilIdle()
        var other = config(); other.prefix = "another-person/"; settings.set(other); await sink.allow()
        await uploads.resumePending(root: dir.deletingLastPathComponent()); await uploads.waitUntilIdle()
        let keys = await sink.keys; XCTAssertEqual(keys.count, 1)
        XCTAssertTrue(S3UploadRecord.read(in: dir)?.message?.contains("destination changed") == true)
        await uploads.enqueue(dir); await uploads.waitUntilIdle()
        let updated = await sink.keys; XCTAssertEqual(updated.count, 2); XCTAssertTrue(updated[1].hasPrefix("another-person/"))
    }
    func testProcessingLockDefersSnapshotWithoutUploadingPartialTranscript() async throws {
        let dir = try fixture(), settings = S3TestSettings(config()), sink = S3TestSink()
        let lock = open(dir.appendingPathComponent(".postprocess.lock").path, O_CREAT | O_RDWR, 0o600)
        defer { flock(lock, LOCK_UN); close(lock) }
        XCTAssertEqual(flock(lock, LOCK_EX | LOCK_NB), 0)
        let uploads = uploader(settings, sink)
        await uploads.enqueue(dir); await uploads.waitUntilIdle()
        let keys = await sink.keys; XCTAssertTrue(keys.isEmpty)
        XCTAssertTrue(S3UploadRecord.read(in: dir)?.retryable == true)
    }
    func testOnlySuccessfulTranscriptionTriggersUploadAndS3FailureKeepsTranscriptReady() async throws {
        for fails in [false, true] {
            let dir = try fixture(), settings = S3TestSettings(config()), sink = S3TestSink(failure: 503)
            let uploads = uploader(settings, sink)
            let coordinator = TranscriptionCoordinator(makeEngine: { _, _ in S3TranscriptionStub(fails: fails) },
                completed: { await uploads.enqueue($0) })
            try await coordinator.regenerate(dir, engine: .parakeet)
            for _ in 0..<300 {
                let state = await coordinator.activity()[dir]
                if state != .queued && state != .processing { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            await uploads.waitUntilIdle()
            let state = await coordinator.activity()[dir], bodies = await sink.bodies
            if fails {
                guard case .failed = state else { return XCTFail("Expected failed transcription") }
                XCTAssertTrue(bodies.isEmpty); XCTAssertNil(S3UploadRecord.read(in: dir))
            } else {
                XCTAssertNil(state)
                XCTAssertEqual(bodies.count, 1)
                XCTAssertTrue(String(decoding: bodies[0], as: UTF8.self).contains("New completed transcription."))
                XCTAssertEqual(S3UploadRecord.read(in: dir)?.phase, .failed)
                let transcript = try JSONDecoder().decode(Transcript.self, from: Data(contentsOf: dir.appendingPathComponent("transcript.json")))
                XCTAssertEqual(transcript.segments[0].text, "New completed transcription.")
            }
        }
    }
    @MainActor func testSettingsSaveKeepsSecretOutOfConfigAndRequiresMatchingKey() async throws {
        let dir = try fixture(), configURL = dir.appendingPathComponent("config.json")
        try Data(#"{"other_setting":"preserved"}"#.utf8).write(to: configURL)
        let settings = S3TestSettings(config())
        let model = S3SettingsModel(configURL: configURL, readSecret: { settings.read($0) },
            saveSecret: { settings.save($0, $1) }, deleteSecret: { settings.remove($0) })
        model.configuration = config()
        let noSecret = await model.save(secret: ""); XCTAssertFalse(noSecret)
        let secret = String(repeating: "s", count: 40)
        let saved = await model.save(secret: secret); XCTAssertTrue(saved); XCTAssertTrue(model.hasSecret)
        let contents = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertFalse(contents.contains(secret)); XCTAssertTrue(contents.contains("preserved"))
        model.configuration.accessKeyID = "AKIAOTHERKEYEXAMPLE"
        let mismatched = await model.save(secret: ""); XCTAssertFalse(mismatched)
        XCTAssertEqual(Config.s3(at: configURL).accessKeyID, config().accessKeyID)
        await model.removeSecret(); XCTAssertFalse(Config.s3(at: configURL).enabled); XCTAssertNil(settings.read(config().accessKeyID))
    }
}

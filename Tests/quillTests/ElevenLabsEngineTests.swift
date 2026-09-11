import AVFoundation
import XCTest
@testable import quill

private let scribeFixture = Data(#"{"language_code":"ron","language_probability":0.99,"text":"Bună dimineața! Mâine discutăm bugetul.","words":[{"text":"Bună","start":0.25,"end":0.5,"type":"word"},{"text":" ","start":0.5,"end":0.5,"type":"spacing"},{"text":"dimineața!","start":0.5,"end":0.95,"type":"word"},{"text":"Mâine","start":1.2,"end":1.6,"type":"word"},{"text":"discutăm","start":2.9,"end":3.3,"type":"word"},{"text":"bugetul.","start":3.3,"end":3.9,"type":"word"}]}"#.utf8)

private final class MockScribeState: @unchecked Sendable {
    let lock = NSLock()
    var count = 0
    var status = 200
    func reset(status: Int = 200) { lock.lock(); defer { lock.unlock() }; count = 0; self.status = status }
    func nextStatus() -> Int { lock.lock(); defer { lock.unlock() }; count += 1; return status }
    func requestCount() -> Int { lock.lock(); defer { lock.unlock() }; return count }
}

private final class MockScribeProtocol: URLProtocol, @unchecked Sendable {
    static let state = MockScribeState()
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "api.elevenlabs.io" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let status = Self.state.nextStatus()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: status == 200 ? scribeFixture : Data("server error with private details".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class ElevenLabsEngineTests: XCTestCase, @unchecked Sendable {
    func testOptInLiveAPIAndCanonicalTranscript() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let audioPath = env["QUILL_TEST_ELEVENLABS_AUDIO"], let key = env["QUILL_TEST_ELEVENLABS_KEY"] else {
            throw XCTSkip("Set QUILL_TEST_ELEVENLABS_AUDIO and QUILL_TEST_ELEVENLABS_KEY for an explicit live API check")
        }
        let audio = URL(fileURLWithPath: audioPath)
        let engine = ElevenLabsEngine(keyProvider: { key })
        try await engine.prepare()
        let segments = try await engine.transcribe(audio)
        let text = segments.map(\.text).joined(separator: " ").lowercased()
        XCTAssertTrue(text.contains("astra"))
        XCTAssertTrue(text.contains("weekly"))
        let transcript = Transcript(engine: engine.name, model: engine.model,
            created_at: ISO8601DateFormatter().string(from: Date()),
            segments: segments.map { Transcript.Segment(speaker: "them", start_ms: Int($0.start * 1000),
                end_ms: Int($0.end * 1000), text: $0.text, source: "system") }, schema_version: 2)
        try transcript.write(to: audio.deletingLastPathComponent())
        print("Live Scribe v2: \(segments.count) segments; Romanian content and canonical transcript verified.")
        await engine.release()
    }

    func testWordsUnicodeSentenceBoundariesAndSilenceGaps() throws {
        let response = try JSONDecoder().decode(ElevenLabsEngine.Response.self, from: scribeFixture)
        let segments = try ElevenLabsEngine.segments(response)
        XCTAssertEqual(segments.map(\.text), ["Bună dimineața!", "Mâine", "discutăm bugetul."])
        XCTAssertEqual(segments[0].start, 0.25)
        XCTAssertEqual(segments[0].end, 0.95)
        XCTAssertEqual(segments.flatMap(\.words).map(\.text), ["Bună", "dimineața!", "Mâine", "discutăm", "bugetul."])
    }

    func testSilenceIsValidButTextWithoutTimingOrBackwardsTimingFails() throws {
        let empty = ElevenLabsEngine.Response(language_code: "ron", language_probability: nil, text: "", words: [])
        XCTAssertTrue(try ElevenLabsEngine.segments(empty).isEmpty)
        let untimed = ElevenLabsEngine.Response(language_code: "ron", language_probability: nil, text: "lost text", words: [])
        XCTAssertThrowsError(try ElevenLabsEngine.segments(untimed))
        for (start, end) in [(-1.0, 1.0), (2, 1), (.infinity, 3), (0, .nan)] {
            let bad = ElevenLabsEngine.Response(language_code: "ron", language_probability: nil, text: "bad",
                words: [.init(text: "bad", start: start, end: end, type: "word")])
            XCTAssertThrowsError(try ElevenLabsEngine.segments(bad))
        }
    }

    func testOfflineFailsBeforeCredentialAccess() async {
        let engine = ElevenLabsEngine(offline: true, keyProvider: { XCTFail("Offline must not read the key"); return nil })
        do { try await engine.prepare(); XCTFail("Expected offline rejection") }
        catch { XCTAssertTrue(String(describing: error).contains("--engine parakeet")) }
    }

    func testMissingKeyFailsBeforeNetwork() async {
        let engine = ElevenLabsEngine(keyProvider: { nil })
        do { try await engine.prepare(); XCTFail("Expected missing-key failure") }
        catch { XCTAssertTrue(String(describing: error).contains("API key")) }
    }

    func testMultipartHasExactOptionsWithoutLanguageHintOrCredentials() throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: work) }
        let audio = work.appendingPathComponent("file with spaces.wav"), body = work.appendingPathComponent("multipart")
        try Data("wave fixture".utf8).write(to: audio)
        try ElevenLabsEngine.writeMultipart(audio: audio, to: body, boundary: "fixture-boundary")
        let text = try String(contentsOf: body, encoding: .utf8)
        XCTAssertTrue(text.contains("name=\"model_id\"\r\n\r\nscribe_v2"))
        XCTAssertTrue(text.contains("name=\"timestamps_granularity\"\r\n\r\nword"))
        XCTAssertTrue(text.contains("name=\"diarize\"\r\n\r\nfalse"))
        XCTAssertTrue(text.hasSuffix("wave fixture\r\n--fixture-boundary--\r\n"))
        XCTAssertFalse(text.contains("language_code"))
        XCTAssertFalse(text.contains("xi-api-key"))
        let mode = try FileManager.default.attributesOfItem(atPath: body.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }

    func testRequestScopeAndErrorMessagesDoNotIncludeServerDetails() throws {
        let request = try ElevenLabsEngine.request(key: "test-secret-not-a-real-key", boundary: "test")
        XCTAssertEqual(request.url?.absoluteString, "https://api.elevenlabs.io/v1/speech-to-text")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "OpenAl File Downloader, XaiImageApiFetch/1.0°")
        XCTAssertNil(request.url?.query)
        for status in [301, 401, 403, 402, 429, 500] {
            XCTAssertThrowsError(try ElevenLabsEngine.checkStatus(status)) { error in
                XCTAssertFalse(String(describing: error).contains("test-secret"))
            }
        }
        XCTAssertNoThrow(try ElevenLabsEngine.checkStatus(200))
    }

    func testRedirectIsRefused() {
        let delegate = ElevenLabsEngine.NoRedirects()
        let destination = URL(string: "https://unexpected.example/upload")!
        let task = URLSession.shared.dataTask(with: destination)
        let response = HTTPURLResponse(url: destination, statusCode: 307, httpVersion: nil, headerFields: nil)!
        delegate.urlSession(.shared, task: task, willPerformHTTPRedirection: response,
            newRequest: URLRequest(url: destination)) { request in XCTAssertNil(request) }
        task.cancel()
    }

    func testCompletedTrackCachePreventsRepeatedUploadsAndChangesInvalidateIt() async throws {
        MockScribeProtocol.state.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockScribeProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let engine = ElevenLabsEngine(keyProvider: { "test-secret-not-a-real-key" }, session: session)
        let work = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: work) }
        let audio = work.appendingPathComponent("mic.caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16000)!
        buffer.frameLength = 16000
        func writeAudio(_ value: Float) throws {
            buffer.floatChannelData![0].update(repeating: value, count: 16000)
            let file = try AVAudioFile(forWriting: audio, settings: format.settings)
            try file.write(from: buffer)
        }
        try writeAudio(0)
        try await engine.prepare()
        _ = try await engine.transcribe(audio)
        _ = try await engine.transcribe(audio)
        XCTAssertEqual(MockScribeProtocol.state.requestCount(), 1)
        let cache = try String(contentsOf: work.appendingPathComponent("elevenlabs-mic.caf.json"), encoding: .utf8)
        XCTAssertFalse(cache.contains("test-secret"))
        try writeAudio(0.1)
        _ = try await engine.transcribe(audio)
        XCTAssertEqual(MockScribeProtocol.state.requestCount(), 2)
        await engine.release()
    }
}

final class ElevenLabsKeychainTests: XCTestCase {
    func testKeyValidationAndSafeLegacyMigration() throws {
        XCTAssertEqual(try ElevenLabsKeychain.validated("  test-key-1234567890\n"), "test-key-1234567890")
        for key in ["", "short", "test-key-1234567890\r\nx-header: injected", "test key with spaces"] {
            XCTAssertThrowsError(try ElevenLabsKeychain.validated(key))
        }
        XCTAssertEqual(Config.migratedEngineName("whisper_cpp"), "parakeet")
        XCTAssertEqual(Config.migratedEngineName("elevenlabs"), "elevenlabs")
        XCTAssertEqual(Config.migratedEngineName(nil), "parakeet")
    }

    func testEncryptedKeychainRoundTrip() throws {
        guard ProcessInfo.processInfo.environment["QUILL_TEST_KEYCHAIN"] == "1" else {
            throw XCTSkip("Set QUILL_TEST_KEYCHAIN=1 for a disposable macOS Keychain test")
        }
        let store = ElevenLabsKeychain(service: "com.bedeabza.quill.test." + UUID().uuidString)
        defer { try? store.remove() }
        XCTAssertFalse(store.containsKey())
        XCTAssertNil(try store.read())
        try store.save("test-secret-first-123456789")
        XCTAssertTrue(store.containsKey())
        XCTAssertEqual(try store.read(), "test-secret-first-123456789")
        try store.save("test-secret-updated-123456789")
        XCTAssertEqual(try store.read(), "test-secret-updated-123456789")
        try store.remove()
        XCTAssertFalse(store.containsKey())
        XCTAssertNil(try store.read())
    }

    func testEngineSelectionPreservesUnrelatedConfiguration() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("config.json")
        try Data(#"{"on_stop":"keep-me","transcription":{"enabled":false,"engine":"parakeet"},"post_processing":{"mode":"codex"}}"#.utf8).write(to: file)
        XCTAssertTrue(Config.setTranscriptionEngine(.elevenLabs, at: file))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual(json["on_stop"] as? String, "keep-me")
        XCTAssertEqual((json["transcription"] as? [String: Any])?["enabled"] as? Bool, false)
        XCTAssertEqual((json["transcription"] as? [String: Any])?["engine"] as? String, "elevenlabs")
        XCTAssertEqual((json["post_processing"] as? [String: String])?["mode"], "codex")
        try Data("broken".utf8).write(to: file)
        XCTAssertFalse(Config.setTranscriptionEngine(.parakeet, at: file))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "broken")
    }
}

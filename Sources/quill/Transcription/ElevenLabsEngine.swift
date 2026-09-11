import AVFoundation
import CryptoKit
import Foundation

/// Cloud transcription through Scribe v2, preserving original track clocks.
actor ElevenLabsEngine: TranscriptionEngine {
    nonisolated let name = TranscriptionEngineKind.elevenLabs.rawValue
    nonisolated let model = "scribe_v2"
    private let offline: Bool
    private let keyProvider: @Sendable () throws -> String?
    private let session: URLSession
    private var prepared = false

    init(offline: Bool = false, keyProvider: @escaping @Sendable () throws -> String? = { try ElevenLabsKeychain.shared.read() },
         session: URLSession? = nil) {
        self.offline = offline
        self.keyProvider = keyProvider
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 1800
        self.session = session ?? URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }

    func prepare() async throws {
        guard !offline else { throw TranscriptionFailure("ElevenLabs requires uploading audio. Use --engine parakeet with --offline.") }
        guard let key = try keyProvider() else { throw TranscriptionFailure("Set your ElevenLabs API key from the Quill menu first.") }
        _ = try ElevenLabsKeychain.validated(key)
        prepared = true
    }

    func transcribe(_ audio: URL) async throws -> [TranscriptSegment] {
        guard prepared else { throw TranscriptionFailure("ElevenLabs engine used before prepare().") }
        // Read again for each track so replacing/removing a key takes effect
        // without restarting Quill, even while the transcription queue is busy.
        guard let key = try keyProvider() else { throw TranscriptionFailure("The ElevenLabs API key is missing. Set it from the Quill menu.") }
        let fingerprint = try Self.fingerprint(audio)
        let cacheURL = audio.deletingLastPathComponent().appendingPathComponent("elevenlabs-\(audio.lastPathComponent).json")
        if let cache = try? JSONDecoder().decode(Cache.self, from: Data(contentsOf: cacheURL)),
           cache.version == 1, cache.model == model, cache.audioSHA256 == fingerprint {
            return try Self.segments(cache.response)
        }
        let probe = try AVAudioFile(forReading: audio)
        guard probe.length > 0 else { throw TranscriptionFailure("Empty audio: \(audio.lastPathComponent)") }
        let duration = Double(probe.length) / probe.processingFormat.sampleRate
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("quill-elevenlabs-" + UUID().uuidString)
        try fm.createDirectory(at: work, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: work) }
        let wav = work.appendingPathComponent("audio.wav")
        let conversion = try await HarnessProcess.run(executable: URL(fileURLWithPath: "/usr/bin/afconvert"),
            arguments: ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", audio.path, wav.path],
            directory: work, timeout: max(120, duration))
        guard conversion.status == 0 else { throw TranscriptionFailure("Could not convert \(audio.lastPathComponent) for ElevenLabs.") }
        let boundary = "quill-" + UUID().uuidString
        let body = work.appendingPathComponent("upload.multipart")
        try Self.writeMultipart(audio: wav, to: body, boundary: boundary)
        let request = try Self.request(key: key, boundary: boundary)
        let data: Data
        let response: URLResponse
        do {
            // One request, without automatic application-level retries or fallback.
            (data, response) = try await session.upload(for: request, fromFile: body)
        } catch {
            throw TranscriptionFailure("Could not reach ElevenLabs or the request timed out. Audio is retained; retry when the connection is available.")
        }
        guard let http = response as? HTTPURLResponse else { throw TranscriptionFailure("ElevenLabs returned an invalid response.") }
        try Self.checkStatus(http.statusCode)
        guard data.count <= 64_000_000 else { throw TranscriptionFailure("ElevenLabs returned an oversized transcript.") }
        let decoded: Response
        do { decoded = try JSONDecoder().decode(Response.self, from: data) }
        catch { throw TranscriptionFailure("ElevenLabs returned a malformed transcript.") }
        let segments = try Self.segments(decoded)
        let cache = Cache(version: 1, model: model, audioSHA256: fingerprint, response: decoded)
        let encoded = try JSONEncoder().encode(cache)
        try encoded.write(to: cacheURL, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cacheURL.path)
        return segments
    }

    func release() async { prepared = false }

    struct Response: Codable, Sendable {
        struct Word: Codable, Sendable {
            let text: String
            let start: Double?
            let end: Double?
            let type: String
        }
        let language_code: String
        let language_probability: Double?
        let text: String
        let words: [Word]
    }

    private struct Cache: Codable {
        let version: Int
        let model: String
        let audioSHA256: String
        let response: Response
    }

    nonisolated static func request(key: String, boundary: String) throws -> URLRequest {
        let key = try ElevenLabsKeychain.validated(key)
        var request = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        request.setValue("OpenAl File Downloader, XaiImageApiFetch/1.0°", forHTTPHeaderField: "User-Agent")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        return request
    }

    nonisolated static func checkStatus(_ status: Int) throws {
        switch status {
        case 200: return
        case 401, 403: throw TranscriptionFailure("ElevenLabs rejected the API key or its speech-to-text permission. Update the key from the Quill menu.")
        case 402, 429: throw TranscriptionFailure("ElevenLabs quota or rate limit reached. Check your account and retry later.")
        default: throw TranscriptionFailure("ElevenLabs transcription failed (HTTP \(status)). Audio is retained for retry.")
        }
    }

    nonisolated static func writeMultipart(audio: URL, to output: URL, boundary: String) throws {
        let fm = FileManager.default
        let size = (try fm.attributesOfItem(atPath: audio.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0, size < 5_000_000_000 else { throw TranscriptionFailure("Audio must be non-empty and smaller than 5 GB for ElevenLabs.") }
        guard fm.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw TranscriptionFailure("Could not prepare the ElevenLabs upload.")
        }
        let destination = try FileHandle(forWritingTo: output)
        let input = try FileHandle(forReadingFrom: audio)
        defer { try? destination.close(); try? input.close() }
        for (name, value) in [("model_id", "scribe_v2"), ("diarize", "false"), ("tag_audio_events", "false"),
                              ("timestamps_granularity", "word"), ("webhook", "false")] {
            try destination.write(contentsOf: Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        try destination.write(contentsOf: Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        while let bytes = try input.read(upToCount: 1_048_576), !bytes.isEmpty { try destination.write(contentsOf: bytes) }
        try destination.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
    }

    nonisolated static func segments(_ response: Response) throws -> [TranscriptSegment] {
        var result: [TranscriptSegment] = []
        var words: [TranscriptWord] = []
        var previousStart = 0.0
        func flush() {
            guard let first = words.first, let last = words.last else { return }
            result.append(TranscriptSegment(start: first.start, end: last.end, text: words.map(\.text).joined(separator: " "), words: words))
            words = []
        }
        for word in response.words where word.type == "word" {
            guard let start = word.start, let end = word.end, start.isFinite, end.isFinite,
                  start >= previousStart, end >= start else {
                throw TranscriptionFailure("ElevenLabs returned invalid word timestamps.")
            }
            previousStart = start
            let text = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if let last = words.last, start - last.end > 1 { flush() }
            words.append(TranscriptWord(start: start, end: end, text: text))
            if text.hasSuffix(".") || text.hasSuffix("?") || text.hasSuffix("!") || words.count >= 60 { flush() }
        }
        flush()
        if result.isEmpty && !response.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw TranscriptionFailure("ElevenLabs returned text without usable word timestamps.")
        }
        return result
    }

    private nonisolated static func fingerprint(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Never forward the API key or recording to an HTTP redirect destination.
    final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}

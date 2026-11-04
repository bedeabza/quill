import AVFoundation
import Foundation
import QuillEchoDSP

/// Creates one meeting-clock waveform. SpeexDSP removes playback correlated
/// with the mic before mixing; original captures are never edited. Streaming
/// frames keep memory bounded for long recordings. No speaker model runs here.
enum MeetingAudio {
    static let version = 1
    static let filename = "meeting-audio.wav"
    static let manifestName = "meeting-audio.json"
    static let cacheName = "elevenlabs-" + filename + ".json"
    static let sampleRate = 16_000
    static let frameSize = 256
    static let filterSamples = 4096

    struct Input: Codable, Equatable, Sendable {
        let file: String
        let source: String
        let offset_ms: Int
        let sha256: String
    }
    struct Span: Codable, Sendable {
        var start: Double
        var end: Double
    }
    struct Manifest: Codable, Sendable {
        let version: Int
        let algorithm: String
        let sample_rate: Int
        let inputs: [Input]
        var audio_sha256: String
        let frames: Int64
        let microphone_energy: Double
        let cleaned_microphone_energy: Double
        let system_energy: Double
        /// Conservative source-only windows, not voice identities. Overlap or
        /// uncertain audio is excluded from UI-name voting, never from the mix.
        let local_windows: [Span]
        let remote_windows: [Span]
    }
    struct Prepared: Sendable {
        let audio: URL
        let manifest: Manifest
    }

    static func identities(directory: URL, meta: SessionMeta) throws -> [Input] {
        guard !meta.tracks.isEmpty else { throw TranscriptionFailure("This recording has no audio tracks.") }
        return try meta.tracks.map { track in
            guard track.offsetMs >= 0, track.offsetMs <= 86_400_000 else {
                throw TranscriptionFailure("Invalid audio start offset in meta.json.")
            }
            let url = directory.appendingPathComponent(track.file)
            guard FileManager.default.isReadableFile(atPath: url.path) else {
                throw TranscriptionFailure("Audio is missing or unreadable: \(track.file). No combined transcript was requested.")
            }
            return Input(file: track.file, source: track.source, offset_ms: track.offsetMs,
                         sha256: try ElevenLabsEngine.fingerprint(url))
        }
    }

    /// Used by cached speaker refresh too: never regenerate audio or upload.
    static func cached(in directory: URL, meta: SessionMeta) throws -> Prepared? {
        try cached(in: directory, inputs: identities(directory: directory, meta: meta))
    }
    private static func cached(in directory: URL, inputs: [Input]) throws -> Prepared? {
        let audio = directory.appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(manifestName)),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
              manifest.version == version, manifest.inputs == inputs,
              manifest.sample_rate == sampleRate, manifest.frames > 0,
              FileManager.default.isReadableFile(atPath: audio.path),
              manifest.audio_sha256 == (try ElevenLabsEngine.fingerprint(audio)) else { return nil }
        return Prepared(audio: audio, manifest: manifest)
    }

    static func prepare(in directory: URL, meta: SessionMeta) async throws -> Prepared {
        let inputs = try identities(directory: directory, meta: meta)
        if let saved = try cached(in: directory, inputs: inputs) { return saved }
        let fm = FileManager.default
        let work = directory.appendingPathComponent(".meeting-audio-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: work) }
        var decoded: [String: URL] = [:]
        for input in inputs {
            let original = directory.appendingPathComponent(input.file)
            let probe = try AVAudioFile(forReading: original)
            guard probe.length > 0 else { throw TranscriptionFailure("Empty audio: \(input.file). Original transcript retained.") }
            let destination = work.appendingPathComponent(input.source + ".wav")
            let result = try await HarnessProcess.run(executable: URL(fileURLWithPath: "/usr/bin/afconvert"),
                arguments: ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", original.path, destination.path],
                directory: work, timeout: max(120, Double(probe.length) / probe.processingFormat.sampleRate))
            guard result.status == 0 else { throw TranscriptionFailure("Could not decode \(input.file) for the meeting recording.") }
            decoded[input.source] = destination
        }
        let decodedInputs = decoded
        let manifest = try await Task.detached(priority: .utility) {
            try mix(inputs: inputs, decoded: decodedInputs, output: work.appendingPathComponent(filename))
        }.value
        guard try identities(directory: directory, meta: meta) == inputs else {
            throw TranscriptionFailure("Original audio changed while preparing the meeting recording. Try again after recording ends.")
        }
        let audio = directory.appendingPathComponent(filename)
        let staged = work.appendingPathComponent(filename)
        // Atomic rename on the recording's own volume; no partial WAV is visible.
        guard rename(staged.path, audio.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: directory.appendingPathComponent(manifestName), options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: audio.path)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: directory.appendingPathComponent(manifestName).path)
        return Prepared(audio: audio, manifest: manifest)
    }

    private final class Reader {
        let file: AVAudioFile
        let offset: Int64
        let buffer: AVAudioPCMBuffer
        var end: Int64 { offset + file.length }
        init(url: URL, offsetMs: Int) throws {
            file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: false)
            offset = Int64(offsetMs) * Int64(sampleRate) / 1000
            guard file.processingFormat.sampleRate == Double(sampleRate), file.processingFormat.channelCount == 1,
                  file.length > 0, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(frameSize)) else {
                throw TranscriptionFailure("Decoded meeting audio has an invalid format.")
            }
            self.buffer = buffer
        }
        func read(at position: Int64, into samples: inout [Int16]) throws {
            samples.withUnsafeMutableBufferPointer { $0.initialize(repeating: 0) }
            let start = max(position, offset), end = min(position + Int64(frameSize), self.end)
            guard end > start else { return }
            if file.framePosition != start - offset { file.framePosition = start - offset }
            var consumed = 0
            let count = Int(end - start)
            while consumed < count {
                try file.read(into: buffer, frameCount: AVAudioFrameCount(count - consumed))
                guard buffer.frameLength > 0, let data = buffer.int16ChannelData?[0] else {
                    throw TranscriptionFailure("Could not read a complete audio frame; no partial meeting will be uploaded.")
                }
                samples.withUnsafeMutableBufferPointer { target in
                    target.baseAddress!.advanced(by: Int(start - position) + consumed).update(from: data, count: Int(buffer.frameLength))
                }
                consumed += Int(buffer.frameLength)
            }
        }
    }

    /// Internal entry point also exercises the actual DSP with synthetic audio.
    static func mix(inputs: [Input], decoded: [String: URL], output: URL) throws -> Manifest {
        // AVAudioFile may retain an autoreleased write handle. Drain it before
        // reading headers/hashing/uploading so the final buffered frames exist.
        var manifest = try autoreleasepool { try render(inputs: inputs, decoded: decoded, output: output) }
        let probe = try AVAudioFile(forReading: output)
        guard probe.length == manifest.frames else { throw TranscriptionFailure("The combined audio did not finalize completely. No upload was started.") }
        manifest.audio_sha256 = try ElevenLabsEngine.fingerprint(output)
        return manifest
    }

    private static func render(inputs: [Input], decoded: [String: URL], output: URL) throws -> Manifest {
        var readers: [String: Reader] = [:]
        for input in inputs {
            guard let url = decoded[input.source] else { throw TranscriptionFailure("A declared audio track was not decoded.") }
            readers[input.source] = try Reader(url: url, offsetMs: input.offset_ms)
        }
        let total = readers.values.map(\.end).max() ?? 0
        guard total > 0, total <= Int64(sampleRate) * 86_400 else { throw TranscriptionFailure("Meeting audio must be non-empty and shorter than 24 hours.") }
        let hasBoth = readers["mic"] != nil && readers["system"] != nil
        let echo = hasBoth ? quill_echo_create(Int32(sampleRate), Int32(frameSize), Int32(filterSamples)) : nil
        guard !hasBoth || echo != nil else { throw TranscriptionFailure("Could not initialize meeting echo cancellation.") }
        defer { if let echo { quill_echo_destroy(echo) } }
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(sampleRate), channels: 1, interleaved: false)!
        var destination: AVAudioFile? = try AVAudioFile(forWriting: output, settings: [AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false], commonFormat: .pcmFormatInt16, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameSize))!
        var mic = [Int16](repeating: 0, count: frameSize), system = mic, clean = mic
        var micEnergy = 0.0, cleanEnergy = 0.0, systemEnergy = 0.0
        var local: [Span] = [], remote: [Span] = []
        func append(_ spans: inout [Span], start: Double, end: Double) {
            if let last = spans.last, abs(last.end - start) < 0.00001 { spans[spans.count - 1].end = end }
            else { spans.append(Span(start: start, end: end)) }
        }
        for position in stride(from: Int64(0), to: total, by: frameSize) {
            try Task.checkCancellation()
            try readers["mic"]?.read(at: position, into: &mic)
            try readers["system"]?.read(at: position, into: &system)
            if let echo { quill_echo_process(echo, mic, system, &clean) }
            else { clean = mic }
            let count = Int(min(Int64(frameSize), total - position))
            var near = 0.0, far = 0.0
            for index in 0..<count {
                // Adaptive filter history must not manufacture a negative echo
                // before mic capture starts or after that capture has ended.
                if let microphone = readers["mic"], position + Int64(index) < microphone.offset || position + Int64(index) >= microphone.end {
                    clean[index] = 0
                }
                let m = Double(mic[index]), c = Double(clean[index]), s = Double(system[index])
                micEnergy += m * m; near += c * c; far += s * s
                let mixed = hasBoth ? (Int32(clean[index]) + Int32(system[index])) / 2
                    : Int32(readers["mic"] != nil ? mic[index] : system[index])
                buffer.int16ChannelData![0][index] = Int16(clamping: mixed)
            }
            cleanEnergy += near; systemEnergy += far
            // Require a clear single-source window before a UI name may vote.
            let nearRMS = sqrt(near / Double(count)), farRMS = sqrt(far / Double(count))
            let start = Double(position) / Double(sampleRate), end = Double(position + Int64(count)) / Double(sampleRate)
            if nearRMS > 200 && farRMS < 100 { append(&local, start: start, end: end) }
            if farRMS > 200 && nearRMS < max(100, farRMS * 0.2) { append(&remote, start: start, end: end) }
            buffer.frameLength = AVAudioFrameCount(count)
            try destination!.write(from: buffer)
        }
        destination = nil
        return Manifest(version: version, algorithm: hasBoth ? "speexdsp-1.2.1-aec-256ms-mix-half" : "single-track-aligned",
            sample_rate: sampleRate, inputs: inputs, audio_sha256: "", frames: total,
            microphone_energy: micEnergy, cleaned_microphone_energy: cleanEnergy, system_energy: systemEnergy,
            local_windows: local, remote_windows: remote)
    }
}

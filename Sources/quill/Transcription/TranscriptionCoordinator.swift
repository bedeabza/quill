import Foundation

/// Post-recording pipeline: a serial queue of session folders to transcribe.
/// mic.caf → "me", system.caf → "them"; each track's segments are shifted by
/// its start offset, merged by timestamp, and written as transcript.json
/// (canonical) plus transcript.md (readable). The filesystem is the queue —
/// `resumePending()` rescans at launch, so a crash or quit mid-transcription
/// just retries on next run. Failures append to the session's transcribe.log
/// and never block later jobs.
actor TranscriptionCoordinator {
    enum Status: Sendable {
        case idle
        case transcribing(session: String, queued: Int)
        case postprocessing(session: String, queued: Int)
        case failed(session: String)
    }

    private var queue: [URL] = []
    private var draining = false
    private var engine: TranscriptionEngine?
    private var engineOffline = false
    private let makeEngine: @Sendable (TranscriptionEngineKind, Bool) -> any TranscriptionEngine
    private var lastFailure: String?
    private var statusHandler: (@Sendable (Status) -> Void)?

    init(makeEngine: @escaping @Sendable (TranscriptionEngineKind, Bool) -> any TranscriptionEngine = { kind, offline in
        switch kind {
        case .parakeet: return ParakeetEngine()
        case .elevenLabs: return ElevenLabsEngine(offline: offline)
        }
    }) {
        self.makeEngine = makeEngine
    }

    func setStatusHandler(_ handler: @escaping @Sendable (Status) -> Void) {
        statusHandler = handler
    }

    /// Queue a finished session. With transcription disabled in config, the
    /// on_stop hook still fires — it just gets an untranscribed folder.
    func enqueue(_ sessionDir: URL) {
        guard Config.transcriptionEnabled() else {
            runHook(for: sessionDir)
            return
        }
        queue.append(sessionDir)
        drainIfIdle()
    }

    /// Scan the recordings root for sessions that finished (meta.json exists)
    /// but were never transcribed. Folder names sort chronologically, so
    /// oldest-first is a name sort.
    func resumePending(root: URL) {
        guard Config.transcriptionEnabled() else { return }
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        ) else { return }

        let fm = FileManager.default
        let pending = entries
            .filter {
                fm.fileExists(atPath: $0.appendingPathComponent("meta.json").path)
                    && !fm.fileExists(atPath: $0.appendingPathComponent("transcript.json").path)
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for dir in pending where !queue.contains(dir) {
            queue.append(dir)
        }
        if !pending.isEmpty {
            FileHandle.standardError.write(Data(
                "resuming \(pending.count) untranscribed session(s)\n".utf8
            ))
        }
        drainIfIdle()
    }

    // MARK: -

    private func drainIfIdle() {
        guard !draining, !queue.isEmpty else { return }
        draining = true
        lastFailure = nil
        Task { await drain() }
    }

    private func drain() async {
        while !queue.isEmpty {
            let dir = queue.removeFirst()
            publish(.transcribing(session: dir.lastPathComponent, queued: queue.count))
            do {
                try await transcribe(dir)
                let cleanupOptions = Config.postProcessing()
                if cleanupOptions.mode != .off { publish(.postprocessing(session: dir.lastPathComponent, queued: queue.count)) }
                let cleanup = await TranscriptPostProcessor.process(dir, options: cleanupOptions)
                log(dir, "postprocess: \(cleanup.status)")
                notifyUser(title: "quill — transcript ready", body: dir.lastPathComponent)
                runHook(for: dir)
            } catch {
                log(dir, "transcription failed: \(error)")
                lastFailure = dir.lastPathComponent
                notifyUser(
                    title: "quill — transcription failed",
                    body: "\(dir.lastPathComponent) — see transcribe.log"
                )
            }
        }
        await engine?.release()
        engine = nil
        publish(lastFailure.map { .failed(session: $0) } ?? .idle)
        draining = false
        // An enqueue that landed between the loop exiting and the release
        // finishing would otherwise sit until the next enqueue.
        drainIfIdle()
    }

    func transcribe(_ dir: URL, detectSpeakers: Bool = Config.speakerDetection(), remoteSpeakerCount: Int? = nil,
                    engineOverride: TranscriptionEngineKind? = nil, offline: Bool = false) async throws {
        let meta = try SessionMeta.read(from: dir)
        // Snapshot the selection for both tracks. Menu changes affect the next job.
        let engine = try await preparedEngine(kind: engineOverride, offline: offline)
        let observationURL = dir.appendingPathComponent("speaker-observations.jsonl")
        let observations = ((try? String(contentsOf: observationURL, encoding: .utf8)) ?? "")
            .split(separator: "\n").compactMap { try? JSONDecoder().decode(SpeakerObservation.self, from: Data($0.utf8)) }

        var merged: [Transcript.Segment] = []
        var analysis = SpeakerAnalysis(turns: [], names: [:])
        var speakerStatus: [String: String] = [:]
        var successfulTracks = 0
        for track in meta.tracks {
            let audio = dir.appendingPathComponent(track.file)
            guard FileManager.default.fileExists(atPath: audio.path) else {
                log(dir, "skipping missing track \(track.file)")
                continue
            }
            log(dir, "transcribing \(track.file) (\(engine.name))")
            // One bad track (empty, truncated) shouldn't cost us the other's
            // transcript — log it and keep going.
            let segments: [TranscriptSegment]
            do {
                segments = try await engine.transcribe(audio)
                successfulTracks += 1
            } catch {
                // Cloud failures must not publish a partial meeting as complete.
                // Successful tracks have their own cache for the next attempt.
                if engine.name == TranscriptionEngineKind.elevenLabs.rawValue { throw error }
                log(dir, "skipping \(track.file): \(error)")
                continue
            }
            let offset = TimeInterval(track.offsetMs) / 1000
            if detectSpeakers && (track.speaker == "them" || meta.sharedMicrophone) && !segments.isEmpty {
                do {
                    log(dir, "separating speakers in \(track.file)")
                    var trackAnalysis = try await SpeakerDiarizer.analyze(audio, source: track.source,
                                                                         speakerCount: track.source == "system" ? remoteSpeakerCount : nil)
                    if let started = meta.audioStartedAt, track.source == "system" {
                        trackAnalysis.named_spans = SpeakerAttribution.nameSpans(turns: trackAnalysis.turns, observations: observations,
                                                               audioStartedAt: started + offset, segments: segments)
                        trackAnalysis.voice_identities = SpeakerAttribution.voiceNames(turns: trackAnalysis.turns, spans: trackAnalysis.named_spans)
                        for span in trackAnalysis.named_spans {
                            trackAnalysis.names[SpeakerAttribution.namedSpeakerID(span.identity, source: track.source)] = span.identity
                        }
                    }
                    merged += SpeakerAttribution.align(segments, turns: trackAnalysis.turns, source: track.source,
                                                       offset: offset, namedSpans: trackAnalysis.named_spans,
                                                       voiceIdentities: trackAnalysis.voice_identities)
                    analysis.turns += trackAnalysis.turns.map { SpeakerTurn(speaker_id: $0.speaker_id, start: $0.start + offset, end: $0.end + offset) }
                    analysis.names.merge(trackAnalysis.names) { _, new in new }
                    if let identities = trackAnalysis.voice_identities {
                        analysis.voice_identities = (analysis.voice_identities ?? [:]).merging(identities) { _, new in new }
                    }
                    analysis.named_spans += trackAnalysis.named_spans.map { NamedSpeakerSpan(start: $0.start + offset, end: $0.end + offset, identity: $0.identity) }
                    speakerStatus[track.source] = trackAnalysis.turns.isEmpty ? "no_speech_detected" : "complete"
                    continue
                } catch {
                    speakerStatus[track.source] = "failed"
                    log(dir, "speaker detection failed for \(track.file): \(error); preserving unlabelled transcript")
                }
            }
            let localName = track.source == "mic" && !meta.sharedMicrophone ? meta.localSpeakerName : nil
            merged += segments.map {
                Transcript.Segment(
                    speaker: track.speaker,
                    start_ms: Int(($0.start + offset) * 1000),
                    end_ms: Int(($0.end + offset) * 1000),
                    text: $0.text,
                    source: track.source,
                    speaker_name: localName,
                    attribution: localName == nil ? "audio_source" : "local_microphone"
                )
            }
        }
        guard successfulTracks > 0 else {
            throw TranscriptionFailure("No audio track could be transcribed. See transcribe.log; the session remains pending.")
        }
        merged.sort { $0.start_ms < $1.start_ms }

        let transcript = Transcript(
            engine: engine.name,
            model: engine.model,
            created_at: ISO8601DateFormatter().string(from: Date()),
            segments: merged,
            schema_version: 2,
            speaker_detection: speakerStatus
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(analysis).write(to: dir.appendingPathComponent("speaker-analysis.json"), options: .atomic)
        try transcript.write(to: dir)
        log(dir, "done — \(merged.count) segments")
    }

    private func preparedEngine(kind override: TranscriptionEngineKind?, offline: Bool) async throws -> TranscriptionEngine {
        guard let kind = override ?? TranscriptionEngineKind(rawValue: Config.transcriptionEngine()) else {
            throw TranscriptionFailure("Unknown transcription engine: \(Config.transcriptionEngine()). Choose an engine from the Quill menu.")
        }
        if let engine, engine.name == kind.rawValue, engineOffline == offline { return engine }
        await engine?.release()
        engine = nil
        let next = makeEngine(kind, offline)
        do { try await next.prepare() }
        catch { await next.release(); throw error }
        engine = next
        engineOffline = offline
        return next
    }

    /// Fires the configured on_stop shell command with the session directory
    /// as its sole argument, after the transcript exists (or immediately after
    /// recording when transcription is disabled).
    private func runHook(for dir: URL) {
        guard let cmd = Config.onStop() else { return }
        let task = Process()
        task.launchPath = "/bin/sh"
        task.arguments = ["-c", "\(cmd) \"$0\"", dir.path]
        do {
            try task.run()
        } catch {
            log(dir, "on_stop hook failed to launch: \(error)")
        }
    }

    private func log(_ dir: URL, _ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        let url = dir.appendingPathComponent("transcribe.log")
        if let handle = FileHandle(forWritingAtPath: url.path) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    private func publish(_ status: Status) {
        statusHandler?(status)
    }
}

/// The slice of meta.json the coordinator needs: which files exist, who they
/// represent, and how far each track started after the earliest one.
struct SessionMeta {
    struct Track {
        let file: String
        let speaker: String
        let offsetMs: Int
        var source: String { speaker == "me" ? "mic" : "system" }
    }

    let tracks: [Track]
    let audioStartedAt: Double?
    let localSpeakerName: String?
    let sharedMicrophone: Bool

    enum MetaError: Error, CustomStringConvertible {
        case unreadable(URL)

        var description: String {
            switch self {
            case .unreadable(let url): return "can't parse \(url.path)"
            }
        }
    }

    static func read(from dir: URL) throws -> SessionMeta {
        let url = dir.appendingPathComponent("meta.json")
        guard
            let data = try? Data(contentsOf: url),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let files = json["files"] as? [String: String]
        else { throw MetaError.unreadable(url) }

        // Sessions recorded before offsets were captured default to 0 —
        // tracks start within tens of milliseconds of each other anyway.
        let offsets = json["start_offset_ms"] as? [String: Int] ?? [:]
        var tracks: [Track] = []
        if let mic = files["mic"] {
            tracks.append(Track(file: mic, speaker: "me", offsetMs: offsets["mic"] ?? 0))
        }
        if let system = files["system"] {
            tracks.append(Track(file: system, speaker: "them", offsetMs: offsets["system"] ?? 0))
        }
        return SessionMeta(tracks: tracks, audioStartedAt: json["audio_started_at"] as? Double,
                           localSpeakerName: SpeakerAttribution.cleanName(json["local_speaker_name"] as? String),
                           sharedMicrophone: json["shared_microphone"] as? Bool ?? false)
    }
}

/// Canonical transcript. Property names are the JSON schema — this struct
/// exists to be serialized.
struct Transcript: Codable, Sendable {
    struct Segment: Codable, Sendable {
        let speaker: String
        let start_ms: Int
        let end_ms: Int
        var text: String
        var source: String? = nil
        var speaker_name: String? = nil
        var attribution: String? = nil

        var displayName: String {
            if let speaker_name { return speaker_name }
            if speaker.hasSuffix("_unknown") { return "Unknown speaker" }
            if let number = speaker.split(separator: "_").last, Int(number) != nil {
                return source == "mic" ? "Local speaker \(number)" : "Speaker \(number)"
            }
            return speaker
        }
    }

    let engine: String
    let model: String
    let created_at: String
    var segments: [Segment]
    var schema_version: Int? = nil
    var speaker_detection: [String: String]? = nil

    /// Write transcript.json and render transcript.md. Both writes are atomic
    /// (temp file + rename), so a partially written transcript never exists on
    /// disk — resumePending treats presence of transcript.json as "done".
    func write(to dir: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try Data(rendered(title: dir.lastPathComponent).utf8)
            .write(to: dir.appendingPathComponent("transcript.md"), options: .atomic)
        try encoder.encode(self)
            .write(to: dir.appendingPathComponent("transcript.json"), options: .atomic)
    }

    private func rendered(title: String) -> String {
        var lines = ["# \(title)", "", "engine: \(engine) (\(model))", ""]
        for seg in segments {
            let name = seg.displayName.replacingOccurrences(of: "*", with: "\\*")
                .replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
            lines.append("**[\(Self.clock(seg.start_ms))] \(name):** \(seg.text)")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private static func clock(_ ms: Int) -> String {
        let total = ms / 1000
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}

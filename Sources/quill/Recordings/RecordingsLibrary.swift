import Foundation

struct RecordingEntry: Sendable {
    let directory: URL
    let title: String
    let startedAt: Date
    let duration: Int?
    let participants: [String]
    let hasTranscript: Bool
    let hasNamedTranscript: Bool
    let canRegenerate: Bool
    var endedAt: Date? = nil
    var titleSource: String? = nil
    var originalTitle: String? = nil
}

struct TranscriptTurn: Identifiable, Equatable, Sendable {
    let id: Int
    /// Seconds from the start of the recording.
    let start: Int
    let speaker: String
    let text: String
}

enum TranscriptPreview: Equatable, Sendable {
    case turns([TranscriptTurn])
    case text(String)
    /// Nothing to show; the message says why.
    case empty(String)
}

enum RecordingsLibrary {
    static func canonicalDirectory(_ url: URL) -> URL {
        URL(fileURLWithPath: url.resolvingSymlinksInPath().standardizedFileURL.path, isDirectory: true)
    }

    static func entries(in root: URL) throws -> [RecordingEntry] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return [] }
        let folders = try fm.contentsOfDirectory(at: canonicalDirectory(root), includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey], options: [.skipsHiddenFiles])
            .map(canonicalDirectory)
        return folders.compactMap { directory -> RecordingEntry? in
            guard let values = try? directory.resourceValues(forKeys: [.isDirectoryKey, .creationDateKey]), values.isDirectory == true,
                  ["meta.json", "mic.caf", "system.caf"].contains(where: { fm.fileExists(atPath: directory.appendingPathComponent($0).path) }) else { return nil }
            let json = (try? Data(contentsOf: directory.appendingPathComponent("meta.json")))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let meta = try? SessionMeta.read(from: directory)
            let roster = (try? Data(contentsOf: directory.appendingPathComponent("participants.json")))
                .flatMap { try? JSONDecoder().decode(ParticipantRoster.self, from: $0) }
            let started = (json?["started"] as? String).flatMap(parseDate)
                ?? folderDate(directory.lastPathComponent) ?? values.creationDate ?? .distantPast
            let generated = RecordingTitles.saved(in: directory)
            let title = generated?.title ?? meta?.meetingTitle.flatMap { $0.isEmpty ? nil : $0 } ?? directory.lastPathComponent
            let duration = (json?["duration_seconds"] as? Int).flatMap { $0 >= 0 ? $0 : nil }
            let ended = (json?["ended"] as? String).flatMap(parseDate).flatMap { $0 >= started ? $0 : nil }
                ?? duration.map { started.addingTimeInterval(Double($0)) }
            let ready = meta.map { !$0.tracks.isEmpty && $0.tracks.allSatisfy { track in
                fm.isReadableFile(atPath: directory.appendingPathComponent(track.file).path)
            } } ?? false
            return RecordingEntry(directory: directory, title: title, startedAt: started,
                duration: duration, participants: roster?.participants.map(\.name).sorted() ?? [],
                hasTranscript: fm.fileExists(atPath: directory.appendingPathComponent("transcript.json").path)
                    || fm.fileExists(atPath: directory.appendingPathComponent("transcript.md").path),
                hasNamedTranscript: fm.fileExists(atPath: directory.appendingPathComponent("transcript-named.json").path)
                    || fm.fileExists(atPath: directory.appendingPathComponent("transcript-named.md").path), canRegenerate: ready,
                endedAt: ended, titleSource: generated?.source, originalTitle: meta?.meetingTitle)
        }.sorted { $0.startedAt == $1.startedAt ? $0.directory.lastPathComponent > $1.directory.lastPathComponent : $0.startedAt > $1.startedAt }
    }

    static func parseDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: text)
    }
    private static func folderDate(_ name: String) -> Date? {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy.MM.dd-HHmm"; formatter.isLenient = false
        return formatter.date(from: String(name.prefix(16)))
    }

    /// Speaker turns from the JSON transcript, consecutive segments of one
    /// speaker merged; else the markdown text; else why there is nothing.
    static func transcript(in directory: URL, named: Bool) throws -> TranscriptPreview {
        let base = named ? "transcript-named" : "transcript"
        let large = TranscriptPreview.empty("This transcript is large. Open its folder to read the complete file.")
        let json = directory.appendingPathComponent(base + ".json")
        let size = (try? json.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= 16_000_000 else { return large }
        if let data = try? Data(contentsOf: json), let transcript = try? JSONDecoder().decode(Transcript.self, from: data) {
            var turns: [TranscriptTurn] = []
            for segment in transcript.segments {
                let speaker = segment.displayName
                if let last = turns.last, last.speaker == speaker {
                    turns[turns.count - 1] = TranscriptTurn(id: last.id, start: last.start, speaker: speaker, text: last.text + " " + segment.text)
                } else {
                    turns.append(TranscriptTurn(id: turns.count, start: max(0, segment.start_ms / 1000), speaker: speaker, text: segment.text))
                }
            }
            return .turns(turns)
        }
        let markdown = directory.appendingPathComponent(base + ".md")
        let markdownSize = (try? markdown.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard markdownSize <= 16_000_000 else { return large }
        if FileManager.default.fileExists(atPath: markdown.path) { return .text(try String(contentsOf: markdown, encoding: .utf8)) }
        return .empty(named ? "No verified named transcript is available." : "No transcript yet. Select an engine and choose Regenerate to transcribe this recording.")
    }
}

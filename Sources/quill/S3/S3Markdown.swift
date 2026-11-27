import Foundation

/// A single readable document, with JSON flow values in valid YAML front matter.
/// Only meeting metadata is read; configuration, credentials, audio and voice embeddings are excluded.
enum S3Markdown {
    static let metadataFiles = ["meta.json", "participants.json", "speaker-mapping.json", "postprocess.json", "speaker-refresh.json", SpeakerIdentities.filename]
    static let signatureFiles = metadataFiles + ["transcript.json", "transcript-named.json"]
    struct Document: Sendable {
        let data: Data
        let stem: String
        let sourceSignature: String
        var hash: String { S3Signing.hash(data) }
    }
    static func json(_ url: URL) throws -> [String: Any] {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 32_000_000 else { throw TranscriptionFailure("Meeting metadata is too large to export.") }
        guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
            throw TranscriptionFailure("Could not read meeting metadata from \(url.lastPathComponent).")
        }
        return object
    }
    static func signature(in directory: URL) -> String {
        let stamps = signatureFiles.map { name in
            let info = try? directory.appendingPathComponent(name).resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            return "\(name):\(info?.contentModificationDate?.timeIntervalSince1970 ?? 0):\(info?.fileSize ?? 0)"
        }
        // Title cache refreshes can rewrite timestamps without changing the displayed title.
        let title = RecordingTitles.saved(in: directory).map { "\($0.title):\($0.source):\($0.status)" } ?? ""
        return S3Signing.hash(Data((stamps.joined(separator: "\n") + title).utf8))
    }
    static func make(in directory: URL) throws -> Document {
        let before = signature(in: directory)
        let session = try json(directory.appendingPathComponent("meta.json"))
        let named = FileManager.default.fileExists(atPath: directory.appendingPathComponent("transcript-named.json").path)
        let filename = named ? "transcript-named.json" : "transcript.json"
        var metadata = try json(directory.appendingPathComponent(filename))
        let decoded = try JSONDecoder().decode(Transcript.self, from: JSONSerialization.data(withJSONObject: metadata))
        let identities = SpeakerIdentities.read(in: directory)
        let transcript = identities.resolved(decoded)
        metadata.removeValue(forKey: "segments")
        let saved = RecordingTitles.saved(in: directory)
        let title = saved?.title ?? transcript.meeting_title ?? session["meeting_title"] as? String ?? "Recorded conversation"
        guard let dateText = session["started"] as? String, let started = RecordingsLibrary.parseDate(dateText) else {
            throw TranscriptionFailure("The recording has no valid start date. Open its folder to inspect meta.json.")
        }
        var header: [String: Any] = ["title": title, "recording_id": directory.lastPathComponent,
            "export_format": "quill-markdown-v1", "session": session,
            "transcript_metadata": metadata, "transcript_file": filename]
        for (file, key) in [("participants.json", "participants"), ("speaker-mapping.json", "speaker_mapping"),
                            ("postprocess.json", "postprocessing"), ("speaker-refresh.json", "speaker_refresh")] {
            let url = directory.appendingPathComponent(file)
            if FileManager.default.fileExists(atPath: url.path) { header[key] = try json(url) }
        }
        header["participant_names"] = identities.participantNames(transcript.participant_roster?.participants.map(\.name) ?? [])
        // The effective map excludes stale voice links after regeneration.
        header["confirmed_identities"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(identities))
        if let saved { header["title_metadata"] = ["source": saved.source, "status": saved.status, "generation_version": saved.generation_version ?? 1] }
        var seen: Set<String> = []
        header["speakers"] = transcript.segments.filter { seen.insert($0.speaker).inserted }.map { segment -> [String: Any] in
            var speaker = ["id": segment.speaker, "name": segment.displayName]
            speaker["source"] = segment.source; speaker["attribution"] = segment.attribution
            speaker["person_id"] = segment.person_id
            speaker["provider_speaker_id"] = segment.provider_speaker_id
            return speaker
        }
        var lines = ["---"]
        for key in header.keys.sorted() {
            let value = try JSONSerialization.data(withJSONObject: header[key]!, options: [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes])
            lines.append("\(key): \(String(decoding: value, as: UTF8.self))")
        }
        lines += ["---", "", "# \(escape(title))", "", "## Transcript", ""]
        for segment in transcript.segments {
            let seconds = max(0, segment.start_ms / 1000)
            let clock = String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
            lines += ["**[\(clock)] \(escape(segment.displayName)):**", "", escape(segment.text), ""]
        }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let normalized = title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let slug = normalized.components(separatedBy: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789").inverted)
            .filter { !$0.isEmpty }.joined(separator: "-")
        let stem = formatter.string(from: started) + "-" + String((slug.isEmpty ? "meeting" : slug).prefix(100))
        guard signature(in: directory) == before else { throw TranscriptionFailure("The transcript changed during export. Try again.") }
        return Document(data: Data(lines.joined(separator: "\n").utf8), stem: stem, sourceSignature: before)
    }
    static func escape(_ text: String) -> String {
        var result = text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        for character in ["\\", "`", "*", "_", "[", "]", "#"] { result = result.replacingOccurrences(of: character, with: "\\" + character) }
        return result
    }
}

import Foundation

/// Optional user config at ~/.config/quill/config.json:
///
///     {
///       "recordings_dir": "~/Recordings",
///       "transcription": { "enabled": true, "engine": "parakeet" },
///       "mic_voice_processing": true,
///       "on_stop": "my-hook"
///     }
///
/// Resolution order for the recordings root: --out flag > config file >
/// ~/Recordings. `on_stop` is a shell command spawned with the session
/// directory as its argument — after the transcript is written, or right
/// after recording when transcription is disabled.
enum Config {
    static func postProcessing() -> PostProcessingOptions {
        PostProcessingOptions(json: load()?["post_processing"] as? [String: Any])
    }

    @discardableResult static func setPostProcessingMode(_ mode: PostProcessingMode) -> Bool {
        let existing = load()
        guard existing != nil || !FileManager.default.fileExists(atPath: path.path) else { return false }
        var config = existing ?? [:]
        var options = config["post_processing"] as? [String: Any] ?? [:]
        options["mode"] = mode.rawValue
        config["post_processing"] = options
        do {
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: path, options: .atomic)
            return true
        } catch { return false }
    }

    static func speakerDetection() -> Bool { load()?["speaker_detection"] as? Bool ?? true }
    static func zoomVisualSpeakerDetection() -> Bool { load()?["zoom_visual_speaker_detection"] as? Bool ?? true }
    static func zoomLocalSpeakerName() -> String? {
        SpeakerAttribution.cleanName(load()?["zoom_local_speaker_name"] as? String) ?? localSpeakerName()
    }
    static func autoMeetingCaptions() -> Bool { load()?["auto_meeting_captions"] as? Bool ?? false }
    static func sharedMicrophone() -> Bool { load()?["shared_microphone"] as? Bool ?? false }
    static func localSpeakerName() -> String? {
        SpeakerAttribution.cleanName(load()?["local_speaker_name"] as? String ?? NSFullUserName())
    }
    static func meetingDetection() -> Bool { load()?["meeting_detection"] as? Bool ?? true }

    @discardableResult static func setMeetingDetection(_ enabled: Bool) -> Bool {
        let existing = load()
        guard existing != nil || !FileManager.default.fileExists(atPath: path.path) else { return false }
        var config = existing ?? [:]
        config["meeting_detection"] = enabled
        do {
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: path, options: .atomic)
            return true
        } catch {
            FileHandle.standardError.write(Data("Could not save meeting detection setting: \(error)\n".utf8))
            return false
        }
    }

    static let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/quill/config.json")

    static let defaultRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Recordings", isDirectory: true)

    /// The configured recordings root, or nil if no config file / no key.
    static func recordingsDir() -> URL? {
        guard let dir = load()?["recordings_dir"] as? String, !dir.isEmpty else { return nil }
        return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// Shell command to spawn after each session's transcript is written (or
    /// after recording, if transcription is disabled), or nil.
    static func onStop() -> String? {
        guard let cmd = load()?["on_stop"] as? String, !cmd.isEmpty else { return nil }
        return cmd
    }

    /// Whether finished recordings are transcribed automatically. Default on.
    static func transcriptionEnabled() -> Bool {
        transcription()?["enabled"] as? Bool ?? true
    }

    /// Configured engine name. Unknown values fail explicitly during preparation.
    static func transcriptionEngine() -> String {
        migratedEngineName(transcription()?["engine"] as? String)
    }

    static func migratedEngineName(_ name: String?) -> String {
        // Removing a local engine must not silently opt other users into uploading audio.
        name == "whisper_cpp" ? "parakeet" : (name ?? "parakeet")
    }

    @discardableResult static func setTranscriptionEngine(_ engine: TranscriptionEngineKind, at url: URL = path) -> Bool {
        do {
            var config: [String: Any] = [:]
            if FileManager.default.fileExists(atPath: url.path) {
                let data = try Data(contentsOf: url)
                guard let existing = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
                config = existing
            }
            var options = config["transcription"] as? [String: Any] ?? [:]
            options["engine"] = engine.rawValue
            config["transcription"] = options
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: .atomic)
            return true
        } catch { return false }
    }

    private static func transcription() -> [String: Any]? {
        load()?["transcription"] as? [String: Any]
    }

    /// Apple voice processing (acoustic echo cancellation) on the mic, so
    /// speaker playback doesn't bleed into the mic track and get transcribed
    /// as "me". Default off — the live voice unit ducks all other playback,
    /// and on headphones there's no echo to cancel anyway. Set true when
    /// recording meetings through the speakers.
    static func micVoiceProcessing() -> Bool {
        load()?["mic_voice_processing"] as? Bool ?? false
    }

    /// Parse the config file. A malformed config is reported on stderr rather
    /// than silently ignored — recordings landing in an unexpected place is
    /// worse than a warning.
    private static func load() -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        guard
            let data = try? Data(contentsOf: path),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            FileHandle.standardError.write(Data(
                "warning: \(path.path) is not valid JSON — ignoring config\n".utf8
            ))
            return nil
        }
        return json
    }

    /// Resolve the recordings root from an optional CLI override.
    static func resolveRoot(cliOverride: String?) -> URL {
        if let cliOverride {
            return URL(
                fileURLWithPath: (cliOverride as NSString).expandingTildeInPath,
                isDirectory: true
            )
        }
        return recordingsDir() ?? defaultRoot
    }
}

import Darwin
import Foundation

/// Holds the same lock as label/refresh/cleanup commands. Previous outputs are
/// retained until replacements succeed and are restored if any track fails.
final class RecordingRegeneration {
    static let outputFiles = ["transcript.json", "transcript.md", "transcript-named.json", "transcript-named.md",
        "speaker-analysis.json", "speaker-mapping.json", "postprocess.json", "speaker-refresh.json",
        MeetingAudio.filename, MeetingAudio.manifestName]
    let directory: URL
    let backup: URL
    private var descriptor: Int32 = -1

    static func validate(_ directory: URL) throws {
        let meta = try SessionMeta.read(from: directory)
        guard !meta.tracks.isEmpty, meta.tracks.allSatisfy({ FileManager.default.isReadableFile(atPath: directory.appendingPathComponent($0.file).path) }) else {
            throw TranscriptionFailure("The recording is unfinished or its audio files are missing. Open its folder to inspect it.")
        }
    }

    init(directory: URL, freshCloud: Bool) throws {
        try Self.validate(directory)
        self.directory = directory
        backup = directory.appendingPathComponent("transcription-backup-" + UUID().uuidString)
        descriptor = open(directory.appendingPathComponent(".postprocess.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw TranscriptionFailure("Could not lock this recording.") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor); descriptor = -1
            throw TranscriptionFailure("This recording is already being processed. Try again when it finishes.")
        }
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: backup, withIntermediateDirectories: false)
            let meta = try SessionMeta.read(from: directory)
            let caches = meta.tracks.map { "elevenlabs-\($0.file).json" } + [MeetingAudio.cacheName]
            for name in Self.outputFiles + caches {
                let original = directory.appendingPathComponent(name)
                if fm.fileExists(atPath: original.path) { try fm.copyItem(at: original, to: backup.appendingPathComponent(name)) }
            }
            if freshCloud {
                // Old per-track responses remain intact for audit/legacy refresh.
                for name in [MeetingAudio.cacheName] {
                    let url = directory.appendingPathComponent(name)
                    if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
                }
            }
        } catch { unlock(); throw error }
    }

    func restore() throws {
        let fm = FileManager.default
        for name in Self.outputFiles {
            let saved = backup.appendingPathComponent(name), destination = directory.appendingPathComponent(name)
            if fm.fileExists(atPath: saved.path) { try Data(contentsOf: saved).write(to: destination, options: .atomic) }
            else if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        }
        // Keep any newly completed cloud track cached for the next retry.
    }

    func finish() throws {
        for name in ["postprocess.json", "speaker-refresh.json"] {
            let url = directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
    }

    func unlock() {
        if descriptor >= 0 { flock(descriptor, LOCK_UN); close(descriptor); descriptor = -1 }
    }
    deinit { unlock() }
}

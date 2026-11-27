import Darwin
import Foundation

/// A discussion's upload permission is independent of its last upload result.
/// Changing the generation revokes pending work, including work in another process.
struct S3SyncPreference: Codable, Equatable, Sendable {
    var blocked = false
    var generation: String? = nil
    static let filename = "s3-sync.json"

    /// Short-lived lock for permission/outbox edits, never held during a request.
    static func lock(in directory: URL) throws -> Int32 {
        let lock = open(directory.appendingPathComponent(".s3-control.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw TranscriptionFailure("Could not save this discussion’s S3 sync preference.") }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            close(lock)
            throw TranscriptionFailure("This discussion’s sync preference is changing in another Quill process. Try again.")
        }
        return lock
    }

    static func read(in directory: URL) -> Self {
        let url = directory.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: url.path) else { return Self() }
        guard let data = try? Data(contentsOf: url), let value = try? JSONDecoder().decode(Self.self, from: data) else {
            // An unreadable permission file must never silently permit an upload.
            return Self(blocked: true, generation: "unreadable")
        }
        return value
    }

    func write(in directory: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: directory.appendingPathComponent(Self.filename), options: .atomic)
    }
}

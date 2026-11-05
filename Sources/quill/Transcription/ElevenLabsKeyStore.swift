import Darwin
import Foundation

/// Keeps the ElevenLabs API key in a plain file only the user's account can
/// read (mode 0600 inside a 0700 folder), so no system dialog is involved.
struct ElevenLabsKeyStore: Sendable {
    static let shared = ElevenLabsKeyStore()
    static let defaultURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Quill", isDirectory: true)
        .appendingPathComponent("elevenlabs-key", isDirectory: false)

    let url: URL

    init(url: URL = defaultURL) { self.url = url }

    enum Access: Equatable, Sendable {
        case available, missing, failed(String)
    }

    /// True when a usable key is saved.
    func containsKey() -> Bool { checkAccess() == .available }

    /// Reads the saved key without validating it with ElevenLabs or exposing it.
    func checkAccess() -> Access {
        do { return try read() == nil ? .missing : .available }
        catch { return .failed(String(describing: error)) }
    }

    func read() throws -> String? {
        // O_NOFOLLOW rejects symlinks; O_NONBLOCK keeps a FIFO from blocking.
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            if errno == ELOOP { throw failure("is not a regular file") }
            throw failure("could not be opened (\(String(cString: strerror(errno))))")
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw failure("could not be inspected (\(String(cString: strerror(errno))))") }
        guard info.st_mode & S_IFMT == S_IFREG else { throw failure("is not a regular file") }
        guard info.st_mode & 0o077 == 0 else { throw failure("can be accessed by other user accounts") }
        let data = try handle.readToEnd() ?? Data()
        guard let value = String(data: data, encoding: .utf8), let key = try? Self.validated(value) else {
            throw failure("does not contain a valid key")
        }
        return key
    }

    func save(_ value: String) throws {
        let key = try Self.validated(value)
        let directory = url.deletingLastPathComponent()
        try prepareDirectory(directory)
        // Created owner-only, so the key never exists with looser permissions.
        let temp = directory.appendingPathComponent(".elevenlabs-key-" + UUID().uuidString)
        let fd = open(temp.path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw saveFailure("create a temporary file") }
        do {
            defer { close(fd) }
            guard fchmod(fd, 0o600) == 0 else { throw saveFailure("set file permissions") }
            let bytes = Array(key.utf8)
            var written = 0
            while written < bytes.count {
                let count = bytes[written...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw saveFailure("write the key") }
                written += count
            }
            guard fsync(fd) == 0 else { throw saveFailure("write the key") }
            var tempURL = temp
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try tempURL.setResourceValues(values)
            guard rename(temp.path, url.path) == 0 else { throw saveFailure("replace the saved key") }
        } catch {
            unlink(temp.path)
            throw error
        }
    }

    /// Removing a key that is not saved succeeds.
    func remove() throws {
        guard unlink(url.path) == 0 || errno == ENOENT else {
            throw TranscriptionFailure("Could not remove the ElevenLabs key at \(url.path) (\(String(cString: strerror(errno)))).")
        }
    }

    static func validated(_ value: String) throws -> String {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (16...1024).contains(key.utf8.count), key.utf8.allSatisfy({ $0 >= 33 && $0 <= 126 }) else {
            throw TranscriptionFailure("Enter a valid ElevenLabs API key without spaces or line breaks.")
        }
        return key
    }

    /// Creates the folder owner-only. An existing folder is tightened only when
    /// it is Quill's own folder owned by this user; anything else is left as is.
    private func prepareDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
        if mkdir(directory.path, 0o700) == 0 {
            guard chmod(directory.path, 0o700) == 0 else { throw saveFailure("set folder permissions") }
            return
        }
        guard errno == EEXIST else { throw saveFailure("create \(directory.path)") }
        var info = stat()
        guard lstat(directory.path, &info) == 0 else { throw saveFailure("inspect \(directory.path)") }
        guard info.st_mode & S_IFMT == S_IFDIR else {
            throw TranscriptionFailure("Could not save the ElevenLabs key: \(directory.path) is not a folder.")
        }
        if directory.lastPathComponent == "Quill", info.st_uid == getuid(), info.st_mode & 0o777 != 0o700 {
            guard chmod(directory.path, 0o700) == 0 else { throw saveFailure("set folder permissions") }
        }
    }

    private func failure(_ problem: String) -> TranscriptionFailure {
        TranscriptionFailure("The ElevenLabs key file at \(url.path) \(problem). Save the key again to replace it.")
    }

    private func saveFailure(_ step: String) -> TranscriptionFailure {
        TranscriptionFailure("Could not save the ElevenLabs key: failed to \(step) (\(String(cString: strerror(errno)))).")
    }
}

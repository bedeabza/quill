import Darwin
import Foundation

/// A bounded subprocess with a private working directory and process group.
/// Output goes to files so a verbose or stalled CLI cannot deadlock a pipe.
enum HarnessProcess {
    struct Result: Sendable {
        let status: Int32
        let output: Data
    }

    enum Failure: Error {
        case launch(Int32), timedOut, outputTooLarge
    }

    static func environment() -> [String: String] {
        let inherited = ProcessInfo.processInfo.environment
        let allowed = ["HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "LANG", "LC_ALL", "CODEX_HOME",
                       "CLAUDE_CONFIG_DIR", "XDG_CONFIG_HOME", "NODE_EXTRA_CA_CERTS", "SSL_CERT_FILE",
                       "HTTPS_PROXY", "HTTP_PROXY", "NO_PROXY"]
        var result = inherited.filter { allowed.contains($0.key) }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        result["PATH"] = [home + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
            .joined(separator: ":")
        result["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] = "1"
        result["DISABLE_AUTOUPDATER"] = "1"
        return result
    }

    static func run(executable: URL, arguments: [String], input: Data = Data(), directory: URL,
                    timeout: Double) async throws -> Result {
        try await Task.detached(priority: .utility) {
            try execute(executable: executable, arguments: arguments, input: input, directory: directory, timeout: timeout)
        }.value
    }

    private static func execute(executable: URL, arguments: [String], input: Data, directory: URL,
                                timeout: Double) throws -> Result {
        let fm = FileManager.default
        let prefix = UUID().uuidString
        let inputURL = directory.appendingPathComponent(prefix + ".input")
        let outputURL = directory.appendingPathComponent(prefix + ".output")
        let errorURL = directory.appendingPathComponent(prefix + ".error")
        for url in [inputURL, outputURL, errorURL] {
            guard fm.createFile(atPath: url.path, contents: url == inputURL ? input : Data(),
                                attributes: [.posixPermissions: 0o600]) else { throw Failure.launch(EIO) }
        }
        defer { for url in [inputURL, outputURL, errorURL] { try? fm.removeItem(at: url) } }
        let stdin = try FileHandle(forReadingFrom: inputURL)
        let stdout = try FileHandle(forWritingTo: outputURL)
        let stderr = try FileHandle(forWritingTo: errorURL)
        defer { try? stdin.close(); try? stdout.close(); try? stderr.close() }

        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0, posix_spawnattr_init(&attributes) == 0 else {
            throw Failure.launch(ENOMEM)
        }
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        for (fd, target) in [(stdin.fileDescriptor, STDIN_FILENO), (stdout.fileDescriptor, STDOUT_FILENO),
                             (stderr.fileDescriptor, STDERR_FILENO)] {
            guard posix_spawn_file_actions_adddup2(&actions, fd, target) == 0 else { throw Failure.launch(EIO) }
        }
        guard posix_spawn_file_actions_addchdir_np(&actions, directory.path) == 0,
              posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0 else { throw Failure.launch(EINVAL) }
        var argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
        var env = environment().map { strdup($0.key + "=" + $0.value) } + [nil]
        defer { argv.forEach { free($0) }; env.forEach { free($0) } }
        var pid: pid_t = 0
        let launched = posix_spawn(&pid, executable.path, &actions, &attributes, &argv, &env)
        guard launched == 0 else { throw Failure.launch(launched) }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var status: Int32 = 0
        while true {
            let waited = waitpid(pid, &status, WNOHANG)
            if waited == pid { break }
            if waited < 0 && errno != EINTR { throw Failure.launch(errno) }
            var outputInfo = stat(), errorInfo = stat()
            _ = fstat(stdout.fileDescriptor, &outputInfo)
            _ = fstat(stderr.fileDescriptor, &errorInfo)
            let tooLarge = outputInfo.st_size > 4_000_000 || errorInfo.st_size > 1_000_000
            if tooLarge || ProcessInfo.processInfo.systemUptime >= deadline {
                kill(-pid, SIGTERM)
                usleep(100_000)
                kill(-pid, SIGKILL)
                while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
                throw tooLarge ? Failure.outputTooLarge : Failure.timedOut
            }
            usleep(25_000)
        }
        let data = try Data(contentsOf: outputURL)
        guard data.count <= 4_000_000 else { throw Failure.outputTooLarge }
        let exitStatus = status & 0x7f == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
        return Result(status: exitStatus, output: data)
    }
}

import AppKit
import Foundation

enum PostProcessingMode: String, Codable, CaseIterable, Sendable {
    case off, auto, codex, claude
}

struct PostProcessingOptions: Sendable {
    var mode: PostProcessingMode = .off
    var timeout: Double = 120
    var glossary: [String] = []

    init(mode: PostProcessingMode = .off, timeout: Double = 120, glossary: [String] = []) {
        self.mode = mode
        self.timeout = timeout.isFinite ? min(600, max(10, timeout)) : 120
        self.glossary = glossary.filter { !$0.isEmpty && $0.count <= 100 }.prefix(100).map { $0 }
    }

    init(json: [String: Any]?) {
        self.init(mode: (json?["mode"] as? String).flatMap(PostProcessingMode.init(rawValue:)) ?? .off,
                  timeout: json?["timeout_seconds"] as? Double ?? 120,
                  glossary: json?["glossary"] as? [String] ?? [])
    }
}

struct TranscriptHarness: Sendable {
    let kind: PostProcessingMode
    let executable: URL

    static func find(_ kind: PostProcessingMode, searchPaths: [String]? = nil) -> TranscriptHarness? {
        guard kind == .codex || kind == .claude else { return nil }
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let paths = searchPaths ?? [home + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
            + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for path in paths where path.hasPrefix("/") {
            let executable = URL(fileURLWithPath: path).appendingPathComponent(kind.rawValue)
            if fm.isExecutableFile(atPath: executable.path) { return TranscriptHarness(kind: kind, executable: executable) }
        }
        return nil
    }

    static func preference(mode: PostProcessingMode, activeApps: [String]) -> [PostProcessingMode] {
        guard mode == .auto else { return mode == .off ? [] : [mode] }
        let claudeActive = activeApps.contains { $0.lowercased().contains("claude") }
        let codexActive = activeApps.contains { $0.lowercased().contains("codex") || $0.lowercased().contains("chatgpt") }
        return claudeActive && !codexActive ? [.claude, .codex] : [.codex, .claude]
    }

    static func select(mode: PostProcessingMode, directory: URL) async -> TranscriptHarness? {
        let apps = await MainActor.run {
            NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        }
        for kind in preference(mode: mode, activeApps: apps) {
            if let harness = find(kind), await harness.isReady(directory: directory) { return harness }
        }
        return nil
    }

    func isReady(directory: URL) async -> Bool {
        let args = kind == .codex ? ["login", "status"] : ["auth", "status", "--json"]
        guard let status = try? await HarnessProcess.run(executable: executable, arguments: args, directory: directory, timeout: 8),
              status.status == 0 else { return false }
        if kind == .claude {
            guard let json = try? JSONSerialization.jsonObject(with: status.output) as? [String: Any],
                  json["loggedIn"] as? Bool == true else { return false }
        }
        // Require the isolation flags, rather than silently weakening them on
        // older CLI versions. No login prompts or installation attempts.
        guard let help = try? await HarnessProcess.run(executable: executable,
                    arguments: kind == .codex ? ["exec", "--help"] : ["--help"], directory: directory, timeout: 8), help.status == 0,
              let text = String(data: help.output, encoding: .utf8) else { return false }
        let required = kind == .codex ? ["--ignore-user-config", "--ephemeral", "--output-schema"]
            : ["--safe-mode", "--tools", "--json-schema", "--no-session-persistence"]
        return required.allSatisfy { text.contains($0) }
    }

    func arguments(schema: URL, output: URL) throws -> [String] {
        if kind == .claude {
            return ["--print", "--safe-mode", "--tools", "", "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}",
                    "--permission-mode", "dontAsk", "--no-session-persistence", "--output-format", "json",
                    "--json-schema", try String(contentsOf: schema, encoding: .utf8)]
        }
        var args = ["exec", "--ignore-user-config", "--ephemeral", "--skip-git-repo-check", "--sandbox", "read-only",
                    "--output-schema", schema.path, "--output-last-message", output.path, "--json",
                    "-c", "approval_policy=\"never\"", "-c", "web_search=\"disabled\"", "-c", "project_doc_max_bytes=0",
                    "-c", "features.skip_host_skill_discovery=true"]
        for feature in ["shell_tool", "apps", "plugins", "hooks", "memories", "multi_agent", "skill_search",
                        "skill_mcp_dependency_install", "view_image", "browser_use", "browser_use_external", "computer_use"] {
            args += ["--disable", feature]
        }
        return args + ["-"]
    }

    func complete(prompt: Data, schema: Data, directory: URL, timeout: Double) async throws -> Data {
        let schemaURL = directory.appendingPathComponent("schema.json")
        let outputURL = directory.appendingPathComponent("result.json")
        try schema.write(to: schemaURL, options: .atomic)
        let result = try await HarnessProcess.run(executable: executable, arguments: arguments(schema: schemaURL, output: outputURL),
                                                   input: prompt, directory: directory, timeout: timeout)
        guard result.status == 0 else { throw PostProcessingFailure.harnessFailed }
        if kind == .codex { return try Data(contentsOf: outputURL) }
        guard let envelope = try JSONSerialization.jsonObject(with: result.output) as? [String: Any],
              envelope["is_error"] as? Bool != true, let structured = envelope["structured_output"] as? [String: Any] else {
            throw PostProcessingFailure.invalidResponse
        }
        return try JSONSerialization.data(withJSONObject: structured)
    }
}

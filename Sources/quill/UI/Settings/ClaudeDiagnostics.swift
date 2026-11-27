import AppKit
import SwiftUI

/// Only fixed event names, numeric codes and curated classifications are persisted.
/// Raw CLI output may contain OAuth URLs, account details or tokens and is never logged.
@MainActor
final class ClaudeDiagnostics {
    static let shared = ClaudeDiagnostics()
    let file: URL
    private(set) var storageFailed = false
    static let limit = 64_000

    enum Event: String {
        case signInStarted, helperMissing, helperFound, scriptPrepared, terminalOpened, terminalFailed
        case loginCompleted, verifyStarted, authStatus, capabilities, syntheticRequest, connected, verificationFailed
    }
    enum Detail: String {
        case ok, failed, notLoggedIn, invalidResponse, unsupportedCLI, timeout, outputTooLarge
        case systemError, launchFailed, authentication, accountOrQuota, network, permission, unknown
    }

    init(file: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Quill/claude-connection.log")) { self.file = file }

    func record(_ event: Event, detail: Detail? = nil, code: Int? = nil) {
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            var data = (try? Data(contentsOf: file)) ?? Data()
            if data.count > Self.limit / 2 { data = Data(data.suffix(Self.limit / 2)); if let newline = data.firstIndex(of: 10) { data = Data(data.suffix(from: data.index(after: newline))) } }
            let os = ProcessInfo.processInfo.operatingSystemVersion
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development"
            // Bundle versions are constrained too: never append arbitrary external strings.
            let safeVersion = version.filter { $0.isASCII && ($0.isLetter || $0.isNumber || ".-".contains($0)) }.prefix(40)
            let line = "\(ISO8601DateFormatter().string(from: Date())) app=\(safeVersion) macOS=\(os.majorVersion).\(os.minorVersion).\(os.patchVersion) \(event.rawValue)" + (detail.map { " result=\($0.rawValue)" } ?? "") + (code.map { " code=\($0)" } ?? "") + "\n"
            data.append(Data(line.utf8))
            try data.write(to: file, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            storageFailed = false
        } catch { storageFailed = true }
    }

    private var receipts: [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: file.deletingLastPathComponent(), includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("claude-login-") && $0.pathExtension == "status" }
    }

    func loginReceipt() -> URL? {
        // record() has prepared the private log directory. Logging failure must not block sign-in.
        guard !storageFailed else { return nil }
        importLoginResults()
        let pending = receipts.sorted { $0.lastPathComponent < $1.lastPathComponent }
        for file in pending.dropLast(9) { try? FileManager.default.removeItem(at: file) }
        let result = file.deletingLastPathComponent().appendingPathComponent("claude-login-" + UUID().uuidString + ".status")
        guard FileManager.default.createFile(atPath: result.path, contents: Data(), attributes: [.posixPermissions: 0o600]) else {
            storageFailed = true; return nil
        }
        return result
    }

    func importLoginResults() {
        for receipt in receipts {
            guard let data = try? Data(contentsOf: receipt), !data.isEmpty else { continue }
            let value = String(decoding: data.prefix(16), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if data.count <= 16, let status = Int(value), (0...255).contains(status) {
                record(.loginCompleted, detail: status == 0 ? .ok : .failed, code: status)
            }
            try? FileManager.default.removeItem(at: receipt)
        }
    }

    func read() -> String {
        importLoginResults()
        guard let data = try? Data(contentsOf: file) else { return "No Claude connection events recorded yet." }
        return String(decoding: data.suffix(Self.limit), as: UTF8.self)
    }

    func clear() {
        do {
            for receipt in receipts { try FileManager.default.removeItem(at: receipt) }
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
            storageFailed = false
        } catch { storageFailed = true }
    }

    static func failure(_ error: Error) -> (Detail, Int?) {
        if let error = error as? HarnessProcess.Failure {
            switch error {
            case .timedOut: return (.timeout, nil)
            case .outputTooLarge: return (.outputTooLarge, nil)
            case .launch(let code): return (.launchFailed, Int(code))
            }
        }
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain || ns.domain == NSPOSIXErrorDomain || ns.domain == NSOSStatusErrorDomain {
            return (.systemError, ns.code)
        }
        return (.unknown, nil)
    }

    static func classify(_ data: Data) -> Detail {
        let text = String(decoding: data.prefix(1_000_000), as: UTF8.self).lowercased()
        if ["unauthorized", "not logged in", "authentication", "invalid token", "expired", "401"].contains(where: text.contains) { return .authentication }
        if ["rate limit", "quota", "billing", "credit", "subscription", "429"].contains(where: text.contains) { return .accountOrQuota }
        if ["enotfound", "econn", "network", "certificate", "proxy", "fetch failed", "timed out"].contains(where: text.contains) { return .network }
        if ["permission denied", "eacces", "eperm"].contains(where: text.contains) { return .permission }
        if ["unknown option", "unknown command", "unrecognized option"].contains(where: text.contains) { return .unsupportedCLI }
        return .unknown
    }

    typealias Run = @Sendable (URL, [String], Data, URL, Double) async throws -> HarnessProcess.Result

    func verify(candidates: [TranscriptHarness] = TranscriptHarness.candidates(.claude),
                run: Run = { try await HarnessProcess.run(executable: $0, arguments: $1, input: $2, directory: $3, timeout: $4) }) async throws -> Bool {
        guard !candidates.isEmpty else { record(.helperMissing); return false }
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("quill-claude-check-" + UUID().uuidString)
        try fm.createDirectory(at: work, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: work) }
        for (index, helper) in candidates.enumerated() {
            record(.helperFound, code: index + 1)
            var stage = Event.authStatus
            do {
                let auth = try await run(helper.executable, ["auth", "status", "--json"], Data(), work, 8)
                let authJSON = (try? JSONSerialization.jsonObject(with: auth.output)) as? [String: Any]
                guard auth.status == 0 else {
                    record(stage, detail: authJSON?["loggedIn"] as? Bool == false ? .notLoggedIn : Self.classify(auth.output + auth.errorOutput), code: Int(auth.status))
                    continue
                }
                guard let loggedIn = authJSON?["loggedIn"] as? Bool else {
                    record(stage, detail: .invalidResponse); continue
                }
                guard loggedIn else { record(stage, detail: .notLoggedIn); continue }
                record(stage, detail: .ok)
                stage = .capabilities
                let help = try await run(helper.executable, ["--help"], Data(), work, 8)
                guard help.status == 0 else { record(stage, detail: Self.classify(help.output + help.errorOutput), code: Int(help.status)); continue }
                let helpText = String(decoding: help.output, as: UTF8.self)
                guard ["--safe-mode", "--tools", "--json-schema", "--no-session-persistence"].allSatisfy(helpText.contains) else {
                    record(stage, detail: .unsupportedCLI); continue
                }
                record(stage, detail: .ok)
                stage = .syntheticRequest
                let schema = work.appendingPathComponent("schema.json")
                try RecordingTitles.schema.write(to: schema)
                let result = try await run(helper.executable, helper.arguments(schema: schema, output: work.appendingPathComponent("result.json")),
                    Data("Return only JSON with the title: Synthetic customer onboarding and account setup review. This is a connection check. Do not use tools.".utf8), work, 35)
                guard result.status == 0 else { record(stage, detail: Self.classify(result.output + result.errorOutput), code: Int(result.status)); continue }
                guard let envelope = try? JSONSerialization.jsonObject(with: result.output) as? [String: Any] else { record(stage, detail: .invalidResponse); continue }
                guard envelope["is_error"] as? Bool != true else { record(stage, detail: Self.classify(result.output)); continue }
                guard let structured = envelope["structured_output"] as? [String: Any],
                      let title = structured["title"] as? String, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    record(stage, detail: .invalidResponse); continue
                }
                record(stage, detail: .ok)
                return true
            } catch {
                let (detail, code) = Self.failure(error)
                record(stage, detail: detail, code: code)
            }
        }
        return false
    }
}

struct ClaudeDiagnosticsView: View {
    let diagnostics: ClaudeDiagnostics
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var storageFailed = false
    @State private var copied = false

    init(diagnostics: ClaudeDiagnostics) {
        self.diagnostics = diagnostics
        _text = State(initialValue: diagnostics.read())
        _storageFailed = State(initialValue: diagnostics.storageFailed)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Claude Connection Log").font(.title2.bold())
            Text("Retry Sign In or Verify Connection, then refresh this log. Copy it to share with support. It contains connection stages and error categories, without credentials, account details or meeting content.")
                .font(.callout).foregroundStyle(.secondary)
            ScrollView { Text(text).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(10) }
                .background(.quaternary.opacity(0.3)).clipShape(RoundedRectangle(cornerRadius: 6))
            if storageFailed { Text("Could not save or clear the log. Check access to Library/Logs/Quill.").foregroundStyle(.red).font(.callout) }
            HStack {
                Button("Refresh") { refresh() }
                Button(copied ? "Copied" : "Copy Log") {
                    refresh(); NSPasteboard.general.clearContents(); copied = NSPasteboard.general.setString(text, forType: .string)
                }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([diagnostics.file]) }
                    .disabled(!FileManager.default.fileExists(atPath: diagnostics.file.path))
                Button("Clear Log") { diagnostics.clear(); refresh() }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 700, height: 440).onAppear { refresh() }
    }
    private func refresh() { text = diagnostics.read(); storageFailed = diagnostics.storageFailed; copied = false }
}

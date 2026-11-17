import AppKit
import Observation
import SwiftUI

/// Starts the official interactive login without handling OAuth credentials in
/// Quill. Verification uses synthetic text, never a saved meeting.
@Observable @MainActor
final class ClaudeSignInModel {
    static let shared = ClaudeSignInModel()
    private(set) var message: String?
    private(set) var isBusy = false
    private(set) var isConnected = false
    @ObservationIgnored private let find: @Sendable () -> URL?
    @ObservationIgnored private let open: @MainActor @Sendable (URL) async throws -> Void
    @ObservationIgnored private let verify: @Sendable () async throws -> Bool

    init(find: @escaping @Sendable () -> URL? = { TranscriptHarness.find(.claude)?.executable },
         open: @escaping @MainActor @Sendable (URL) async throws -> Void = { script in
             _ = try await NSWorkspace.shared.open([script],
                 withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
                 configuration: NSWorkspace.OpenConfiguration())
         },
         verify: @escaping @Sendable () async throws -> Bool = {
             let fm = FileManager.default
             let work = fm.temporaryDirectory.appendingPathComponent("quill-claude-check-" + UUID().uuidString)
             try fm.createDirectory(at: work, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
             defer { try? fm.removeItem(at: work) }
             guard let helper = await TranscriptHarness.select(mode: .claude, directory: work) else { return false }
             let data = try await helper.complete(
                 prompt: Data("Return only JSON with the title: Synthetic customer onboarding and account setup review. This is a connection check. Do not use tools.".utf8),
                 schema: RecordingTitles.schema, directory: work, timeout: 35)
             return (try? JSONSerialization.jsonObject(with: data) as? [String: String])?["title"] != nil
         }) {
        self.find = find; self.open = open; self.verify = verify
    }

    func signIn() async {
        guard !isBusy else { return }
        guard let executable = find() else {
            message = "Claude Code was not found. Install it, then return here to sign in."
            return
        }
        isBusy = true; isConnected = false
        defer { isBusy = false }
        var script: URL?
        do {
            let created = try Self.loginScript(executable: executable)
            script = created
            try await open(created)
            message = "Complete the Claude sign-in in the browser opened by Terminal. If a code is shown, paste it in Terminal. Then return here and click Verify Connection."
        } catch {
            if let script { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
            message = "Could not open Claude sign-in. Try again or check that Terminal can open on this Mac."
        }
    }

    func checkConnection() async {
        guard !isBusy else { return }
        isBusy = true; isConnected = false; message = "Checking Claude connection…"
        defer { isBusy = false }
        do { isConnected = try await verify() } catch { isConnected = false }
        message = isConnected ? "Claude is connected. You can now refresh the meeting title."
            : "Claude could not complete the connection check. Sign in again and check your Claude account availability."
    }

    static func loginScript(executable: URL) throws -> URL {
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("quill-claude-login-" + UUID().uuidString)
        try fm.createDirectory(at: work, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let script = work.appendingPathComponent("Sign In to Claude.command")
        do {
            let source = """
            #!/bin/sh
            cd /private/tmp || exit 1
            printf '%s\\n' 'Quill: sign in to Claude in the browser. Return to Quill and click Verify Connection when finished.'
            \(quote(executable.path)) auth login --claudeai
            quill_login_status=$?
            rm -f -- "$0"
            rmdir -- \(quote(work.path)) 2>/dev/null || true
            exit "$quill_login_status"

            """
            try Data(source.utf8).write(to: script, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            return script
        } catch { try? fm.removeItem(at: work); throw error }
    }
}

struct ClaudeSignInView: View {
    @State private var model = ClaudeSignInModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button("Sign In to Claude…") { Task { await model.signIn() } }
                Button("Verify Connection") { Task { await model.checkConnection() } }
                if model.isBusy { ProgressView().controlSize(.small) }
                if model.isConnected { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
            }
            .disabled(model.isBusy)
            Text(model.message ?? "Connect the Claude Code account used for AI titles. Sign-in opens Terminal and the official browser flow; Quill does not ask for your password.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Verify Connection sends a short test message without meeting content. Afterwards, use Refresh Title on the recording.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct ClaudeSignInSheet: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Connect Claude").font(.title2.bold())
            ClaudeSignInView()
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(24)
        .frame(width: 460)
    }
}

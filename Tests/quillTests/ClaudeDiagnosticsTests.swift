import XCTest
@testable import quill

@MainActor
final class ClaudeDiagnosticsTests: XCTestCase {
    private func log() throws -> ClaudeDiagnostics {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("quill-diagnostics-test-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return ClaudeDiagnostics(file: root.appendingPathComponent("claude-connection.log"))
    }
    private var helper: TranscriptHarness { .init(kind: .claude, executable: URL(fileURLWithPath: "/fixture/claude")) }
    nonisolated private static let help = Data("--safe-mode --tools --json-schema --no-session-persistence".utf8)

    func testLogPersistsIsPrivateBoundedAndCanBeCleared() throws {
        let diagnostics = try log()
        for _ in 0..<800 { diagnostics.record(.authStatus, detail: .notLoggedIn) }
        let contents = diagnostics.read()
        XCTAssertTrue(contents.contains("authStatus result=notLoggedIn"))
        XCTAssertLessThanOrEqual(contents.utf8.count, ClaudeDiagnostics.limit)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: diagnostics.file.path)[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: diagnostics.file.deletingLastPathComponent().path)[.posixPermissions] as? Int, 0o700)
        XCTAssertEqual(ClaudeDiagnostics(file: diagnostics.file).read(), contents)
        diagnostics.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: diagnostics.file.path))
    }

    func testMissingAndLoggedOutHelpersHaveDistinctDiagnostics() async throws {
        let diagnostics = try log()
        let missing = try await diagnostics.verify(candidates: [])
        XCTAssertFalse(missing)
        for status: Int32 in [0, 1] {
            let loggedOut = try await diagnostics.verify(candidates: [helper], run: { _, args, _, _, _ in
                XCTAssertEqual(args, ["auth", "status", "--json"])
                return .init(status: status, output: Data("{\"loggedIn\":false,\"email\":\"private@example.test\"}".utf8))
            })
            XCTAssertFalse(loggedOut)
        }
        XCTAssertTrue(diagnostics.read().contains("helperMissing"))
        XCTAssertTrue(diagnostics.read().contains("notLoggedIn"))
        XCTAssertFalse(diagnostics.read().contains("private@example"))
    }

    func testOldCLIAndMalformedAuthAreIdentifiedBeforeRequest() async throws {
        let diagnostics = try log()
        let old = try await diagnostics.verify(candidates: [helper], run: { _, args, _, _, _ in
            if args.first == "auth" { return .init(status: 0, output: Data("{\"loggedIn\":true}".utf8)) }
            XCTAssertEqual(args, ["--help"])
            return .init(status: 0, output: Data("old cli --tools".utf8))
        })
        XCTAssertFalse(old)
        XCTAssertTrue(diagnostics.read().contains("capabilities result=unsupportedCLI"))
        let malformed = try await diagnostics.verify(candidates: [helper], run: { _, _, _, _, _ in .init(status: 0, output: Data("not json SECRET".utf8)) })
        XCTAssertFalse(malformed)
        XCTAssertTrue(diagnostics.read().contains("authStatus result=invalidResponse"))
        XCTAssertFalse(diagnostics.read().contains("SECRET"))
    }

    func testSyntheticRequestSuccessAndFailuresNeverLogRawOutput() async throws {
        let diagnostics = try log()
        for failure in ["", "expired token SECRET https://example.test/oauth?code=SECRET", "quota reached SECRET", "proxy certificate SECRET"] {
            let connected = try await diagnostics.verify(candidates: [helper], run: { _, args, input, _, _ in
                if args.first == "auth" { return .init(status: 0, output: Data("{\"loggedIn\":true}".utf8)) }
                if args == ["--help"] { return .init(status: 0, output: Self.help) }
                XCTAssertTrue(args.contains("--safe-mode"))
                XCTAssertTrue(args.contains("--no-session-persistence"))
                XCTAssertTrue(String(decoding: input, as: UTF8.self).contains("Synthetic"))
                return failure.isEmpty ? .init(status: 0, output: Data("{\"structured_output\":{\"title\":\"SECRET\"}}".utf8))
                    : .init(status: 1, output: Data(), errorOutput: Data(failure.utf8))
            })
            XCTAssertEqual(connected, failure.isEmpty)
        }
        let text = diagnostics.read()
        for category in ["ok", "authentication", "accountOrQuota", "network"] { XCTAssertTrue(text.contains("syntheticRequest result=" + category)) }
        for secret in ["SECRET", "https://", "oauth", "code=SECRET"] { XCTAssertFalse(text.contains(secret)) }
    }

    func testTimeoutLaunchAndInvalidResponseStayDistinct() async throws {
        let diagnostics = try log()
        for failure in [HarnessProcess.Failure.timedOut, .launch(13), .outputTooLarge] {
            let result = try await diagnostics.verify(candidates: [helper], run: { _, _, _, _, _ in throw failure })
            XCTAssertFalse(result)
        }
        for category in ["timeout", "launchFailed code=13", "outputTooLarge"] { XCTAssertTrue(diagnostics.read().contains(category)) }
        let model = ClaudeSignInModel(find: { nil }, open: { _ in }, verify: { throw TranscriptionFailure("SECRET token") }, diagnostics: diagnostics)
        await model.checkConnection()
        XCTAssertFalse(model.isConnected)
        XCTAssertTrue(model.message?.contains("Connection Log") == true)
        XCTAssertFalse(diagnostics.read().contains("SECRET"))
    }

    func testTerminalLoginRecordsOnlyExitStatusAndCleansScript() async throws {
        let diagnostics = try log()
        diagnostics.record(.signInStarted)
        let receipt = try XCTUnwrap(diagnostics.loginReceipt())
        let helper = diagnostics.file.deletingLastPathComponent().appendingPathComponent("helper ' $(not-a-command)")
        try Data("#!/bin/sh\nprintf '%s\\n' 'SECRET oauth code'\nexit 7\n".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let script = try ClaudeSignInModel.loginScript(executable: helper, resultFile: receipt)
        let result = try await HarnessProcess.run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: [script.path], directory: helper.deletingLastPathComponent(), timeout: 5)
        XCTAssertEqual(result.status, 7)
        let text = diagnostics.read()
        XCTAssertTrue(text.contains("loginCompleted result=failed code=7"))
        XCTAssertFalse(text.contains("SECRET"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: script.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: receipt.path))
        XCTAssertEqual(text, diagnostics.read())
    }

    func testLogWriteFailureDoesNotPreventSignIn() async throws {
        let root = try log().file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let blocker = root.appendingPathComponent("file")
        try Data().write(to: blocker)
        let diagnostics = ClaudeDiagnostics(file: blocker.appendingPathComponent("cannot-write.log"))
        let model = ClaudeSignInModel(find: { URL(fileURLWithPath: "/fixture/claude") }, open: { url in
            try FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }, diagnostics: diagnostics)
        await model.signIn()
        XCTAssertTrue(diagnostics.storageFailed)
        XCTAssertTrue(model.message?.contains("Complete the Claude sign-in") == true)
        XCTAssertFalse(model.isBusy)
    }
    func testInvalidLoginReceiptCannotInjectLogContent() throws {
        let diagnostics = try log()
        diagnostics.record(.signInStarted)
        let receipt = try XCTUnwrap(diagnostics.loginReceipt())
        try Data("SECRET https://example.test/oauth?code=abc".utf8).write(to: receipt)
        XCTAssertFalse(diagnostics.read().contains("SECRET"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: receipt.path))
    }

    func testErrorEnvelopeAndMalformedTitleAreNotSuccessfulConnections() async throws {
        let diagnostics = try log()
        for response in ["{\"is_error\":true,\"result\":\"authentication SECRET\"}", "{\"structured_output\":{\"title\":\"  \"}}"] {
            let connected = try await diagnostics.verify(candidates: [helper], run: { _, args, _, _, _ in
                if args.first == "auth" { return .init(status: 0, output: Data("{\"loggedIn\":true}".utf8)) }
                if args == ["--help"] { return .init(status: 0, output: Self.help) }
                return .init(status: 0, output: Data(response.utf8))
            })
            XCTAssertFalse(connected)
        }
        XCTAssertTrue(diagnostics.read().contains("syntheticRequest result=authentication"))
        XCTAssertTrue(diagnostics.read().contains("syntheticRequest result=invalidResponse"))
        XCTAssertFalse(diagnostics.read().contains("SECRET"))
    }

}

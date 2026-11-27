import XCTest
@testable import quill

@MainActor
final class ClaudeSignInTests: XCTestCase {
    private func diagnostics() -> ClaudeDiagnostics {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("quill-signin-log-test-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return ClaudeDiagnostics(file: root.appendingPathComponent("connection.log"))
    }

    func testMissingHelperDoesNotOpenAnything() async {
        let model = ClaudeSignInModel(find: { nil }, open: { _ in XCTFail("Cannot open without a helper") }, verify: { false }, diagnostics: diagnostics())
        await model.signIn()
        XCTAssertTrue(model.message?.contains("not found") == true)
        XCTAssertFalse(model.isBusy)
        XCTAssertFalse(model.isConnected)
    }

    func testSignInOpensOnlyThePreparedLoginAndFailureCleansUp() async throws {
        var script: URL?
        let model = ClaudeSignInModel(find: { URL(fileURLWithPath: "/fixture/claude") }, open: { url in
            script = url
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
            throw TranscriptionFailure("Synthetic launch refusal")
        }, verify: { false }, diagnostics: diagnostics())
        await model.signIn()
        XCTAssertNotNil(script)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(script).deletingLastPathComponent().path))
        XCTAssertTrue(model.message?.contains("Could not open") == true)
        XCTAssertFalse(model.isBusy)
    }

    func testSuccessfulConnectionRequiresTheSyntheticCheckNotJustStoredCredentials() async {
        let ready = ClaudeSignInModel(find: { nil }, open: { _ in }, verify: { true }, diagnostics: diagnostics())
        XCTAssertFalse(ready.isConnected)
        await ready.checkConnection()
        XCTAssertTrue(ready.isConnected)
        XCTAssertTrue(ready.message?.contains("refresh") == true)
        let expired = ClaudeSignInModel(find: { nil }, open: { _ in }, verify: { throw TranscriptionFailure("Synthetic expired credential") }, diagnostics: diagnostics())
        await expired.checkConnection()
        XCTAssertFalse(expired.isConnected)
        XCTAssertFalse(expired.isBusy)
        XCTAssertTrue(expired.message?.contains("Sign in again") == true)
    }

    func testLoginScriptQuotesTheHelperPathAndDeletesItself() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("quill-login-fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = root.appendingPathComponent("claude ' $(touch SHOULD_NOT_EXIST)")
        try Data("#!/bin/sh\nprintf 'ARG:%s\\n' \"$@\"\n".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let script = try ClaudeSignInModel.loginScript(executable: helper)
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: script.path)[.posixPermissions] as? Int, 0o700)
        let result = try await HarnessProcess.run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: [script.path], directory: root, timeout: 5)
        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(String(decoding: result.output, as: UTF8.self).contains("ARG:auth\nARG:login\nARG:--claudeai"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: script.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("SHOULD_NOT_EXIST").path))
    }
}

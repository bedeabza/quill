import Foundation
import Security
import XCTest
@testable import quill

private struct PermissionsKeyStore: ElevenLabsKeychain.Storage {
    var value: String? = "test-key-1234567890123456"
    var failure: OSStatus?
    var requireNoInteraction = true
    func revision() throws -> ElevenLabsKeychain.Revision? { nil }
    func read() throws -> ElevenLabsKeychain.Credential? {
        var allowed = DarwinBoolean(true)
        guard SecKeychainGetUserInteractionAllowed(&allowed) == errSecSuccess,
              !requireNoInteraction || !allowed.boolValue else {
            throw ElevenLabsKeychain.Failure(status: errSecParam)
        }
        if let failure { throw ElevenLabsKeychain.Failure(status: failure) }
        return value.map { .init(value: $0, revision: nil) }
    }
    func save(_ value: String) throws {}
    func remove() throws {}
}

final class PermissionsReportTests: XCTestCase, @unchecked Sendable {
    func testExplicitAuthorizationDoesNotDependOnMetadataBeingAccessible() throws {
        let store = ElevenLabsKeychain(storage: PermissionsKeyStore(requireNoInteraction: false))
        // This storage returns no metadata. Explicit authorization must still
        // attempt the secret read, rather than silently reporting no key.
        XCTAssertTrue(try store.authorizeAccess())
        XCTAssertFalse(try ElevenLabsKeychain(storage: PermissionsKeyStore(value: nil, requireNoInteraction: false)).authorizeAccess())
    }

    func testKeyProbeSuppressesDialogsAndRestoresInteractionFlag() throws {
        var before = DarwinBoolean(false)
        XCTAssertEqual(SecKeychainGetUserInteractionAllowed(&before), errSecSuccess)
        let store = ElevenLabsKeychain(storage: PermissionsKeyStore())
        XCTAssertEqual(store.checkAccess(), .available)
        var after = DarwinBoolean(false)
        XCTAssertEqual(SecKeychainGetUserInteractionAllowed(&after), errSecSuccess)
        XCTAssertEqual(before.boolValue, after.boolValue)
    }

    func testKeyProbeDistinguishesMissingApprovalAndInvalidCredentials() {
        XCTAssertEqual(ElevenLabsKeychain(storage: PermissionsKeyStore(value: nil)).checkAccess(), .missing)
        for status in [errSecInteractionNotAllowed, errSecAuthFailed] {
            XCTAssertEqual(ElevenLabsKeychain(storage: PermissionsKeyStore(failure: status)).checkAccess(), .needsAuthorization)
        }
        let invalid = ElevenLabsKeychain(storage: PermissionsKeyStore(value: "invalid")).checkAccess()
        guard case .failed = invalid else { return XCTFail("Invalid key must not be marked ready") }
        let cancelled = ElevenLabsKeychain(storage: PermissionsKeyStore(failure: errSecUserCanceled)).checkAccess()
        guard case .failed = cancelled else { return XCTFail("Cancellation must remain actionable") }
    }

    func testFolderProbeCleansUpAndPreservesExistingFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = Data("keep original".utf8)
        try original.write(to: root.appendingPathComponent("transcript.md"))
        let check = PermissionsReport.folder(root)
        guard case .ok = check.status else { return XCTFail("Writable folder should pass") }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("transcript.md")), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["transcript.md"])
    }

    func testMissingFolderAndUnfinishedRecordingFail() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        guard case .fail = PermissionsReport.folder(missing).status else { return XCTFail("Missing folder should fail") }
        guard case .fail = PermissionsReport.recording(missing).status else { return XCTFail("Missing audio should fail") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
    }

    func testCloudReadinessNeverTreatsMissingOrLockedKeysAsReady() {
        for access in [ElevenLabsKeychain.Access.missing, .needsAuthorization, .failed("Denied")] {
            guard case .fail = PermissionsReport.transcription(engine: .elevenLabs, access: access).status else {
                return XCTFail("Cloud engine must not pass without readable credentials")
            }
        }
        let ready = PermissionsReport.transcription(engine: .elevenLabs, access: .available)
        guard case .ok = ready.status else { return XCTFail("Readable key should pass the local check") }
        XCTAssertTrue(ready.remediation?.contains("only when ElevenLabs accepts") == true)
    }
}

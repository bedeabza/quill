import Foundation
import XCTest
@testable import quill

final class PermissionsReportTests: XCTestCase, @unchecked Sendable {
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
        for access in [ElevenLabsKeyStore.Access.missing, .failed("Denied")] {
            guard case .fail = PermissionsReport.transcription(engine: .elevenLabs, access: access).status else {
                return XCTFail("Cloud engine must not pass without readable credentials")
            }
        }
        let ready = PermissionsReport.transcription(engine: .elevenLabs, access: .available)
        guard case .ok = ready.status else { return XCTFail("Readable key should pass the local check") }
        XCTAssertTrue(ready.remediation?.contains("only when ElevenLabs accepts") == true)
    }
}

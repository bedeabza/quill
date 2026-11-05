import Foundation
import XCTest
@testable import quill

final class ElevenLabsKeyStoreTests: XCTestCase {
    private var root: URL!
    private var store: ElevenLabsKeyStore!
    private var file: URL { store.url }
    private var folder: URL { store.url.deletingLastPathComponent() }

    override func setUpWithError() throws {
        // Never the real Application Support folder.
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        store = ElevenLabsKeyStore(url: root.appendingPathComponent("Quill/elevenlabs-key"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func mode(_ url: URL) throws -> Int {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
    }

    func testKeyValidation() throws {
        XCTAssertEqual(try ElevenLabsKeyStore.validated("  test-key-1234567890\n"), "test-key-1234567890")
        for key in ["", "short", "test-key-1234567890\r\nx-header: injected", "test key with spaces"] {
            XCTAssertThrowsError(try ElevenLabsKeyStore.validated(key))
        }
    }

    func testSaveReadRoundTripIsOwnerOnlyAndExcludedFromBackup() throws {
        XCTAssertNil(try store.read())
        try store.save("  test-secret-first-123456789\n")
        XCTAssertEqual(try store.read(), "test-secret-first-123456789")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "test-secret-first-123456789")
        XCTAssertEqual(try mode(file), 0o600)
        XCTAssertEqual(try mode(folder), 0o700)
        XCTAssertEqual(try file.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["elevenlabs-key"])
    }

    func testSaveReplacesExistingKeyAndRemoveIsIdempotent() throws {
        XCTAssertNoThrow(try store.remove())
        try store.save("test-secret-first-123456789")
        try store.save("test-secret-updated-123456789")
        XCTAssertEqual(try store.read(), "test-secret-updated-123456789")
        XCTAssertEqual(try mode(file), 0o600)
        try store.remove()
        XCTAssertNil(try store.read())
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertNoThrow(try store.remove())
    }

    func testReadRejectsFileOthersCanAccessWithoutChangingIt() throws {
        try store.save("test-secret-first-123456789")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        XCTAssertThrowsError(try store.read()) { error in
            XCTAssertTrue(String(describing: error).contains("Save the key again"))
        }
        XCTAssertEqual(try mode(file), 0o644)
    }

    func testInvalidKeyIsRejectedWithoutWriting() throws {
        XCTAssertThrowsError(try store.save("test key with spaces"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        try store.save("test-secret-first-123456789")
        XCTAssertThrowsError(try store.save("short"))
        XCTAssertEqual(try store.read(), "test-secret-first-123456789")
    }

    func testCheckAccess() throws {
        XCTAssertEqual(store.checkAccess(), .missing)
        XCTAssertFalse(store.containsKey())
        try store.save("test-secret-first-123456789")
        XCTAssertEqual(store.checkAccess(), .available)
        XCTAssertTrue(store.containsKey())
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        guard case .failed(let message) = store.checkAccess() else { return XCTFail("Readable by others must fail") }
        XCTAssertTrue(message.contains(file.path))
        XCTAssertFalse(store.containsKey())
    }
}

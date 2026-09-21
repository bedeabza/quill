import AppKit
import Security
import XCTest
@testable import quill

private final class MemoryKeychain: ElevenLabsKeychain.Storage, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String? = "test-original-key-123456"
    private var generation = UUID().uuidString
    private var reads = 0
    private var failure: OSStatus?
    var beforeRevision: (@Sendable () -> Void)?

    var readCount: Int { lock.withLock { reads } }
    func fail(with status: OSStatus?) { lock.withLock { failure = status } }

    private func checkFailure() throws {
        if let failure { throw ElevenLabsKeychain.Failure(status: failure) }
    }

    private var currentRevision: ElevenLabsKeychain.Revision {
        // Deliberately identical dates: changes within one second must work.
        .init(created: Date(timeIntervalSince1970: 10), modified: Date(timeIntervalSince1970: 20),
              generation: Data(generation.utf8))
    }

    func revision() throws -> ElevenLabsKeychain.Revision? {
        beforeRevision?()
        return try lock.withLock {
            try checkFailure()
            return value == nil ? nil : currentRevision
        }
    }

    func read() throws -> ElevenLabsKeychain.Credential? {
        try lock.withLock {
            reads += 1
            try checkFailure()
            return value.map { .init(value: $0, revision: currentRevision) }
        }
    }

    func save(_ value: String) throws {
        try lock.withLock {
            try checkFailure()
            self.value = value
            generation = UUID().uuidString
        }
    }

    func remove() throws {
        try lock.withLock {
            try checkFailure()
            value = nil
        }
    }
}

final class KeychainAccessTests: XCTestCase, @unchecked Sendable {
    func testPreparationTracksAndMeetingsReadSecretOnlyOnce() throws {
        let backend = MemoryKeychain()
        let store = ElevenLabsKeychain(storage: backend)
        for _ in 0..<10 {
            XCTAssertTrue(store.containsKey())
            XCTAssertEqual(try store.read(), "test-original-key-123456")
        }
        XCTAssertEqual(backend.readCount, 1)
    }

    func testConcurrentRequestsShareOneAuthorization() async throws {
        let backend = MemoryKeychain()
        let store = ElevenLabsKeychain(storage: backend)
        let values = try await withThrowingTaskGroup(of: String?.self) { group in
            for _ in 0..<20 { group.addTask { try store.read() } }
            var values: [String?] = []
            for try await value in group { values.append(value) }
            return values
        }
        XCTAssertEqual(values.count, 20)
        XCTAssertTrue(values.allSatisfy { $0 == "test-original-key-123456" })
        XCTAssertEqual(backend.readCount, 1)
    }

    func testMenuAndExternalUpdatesInvalidateCachedKeyEvenWithSameDates() throws {
        let backend = MemoryKeychain()
        let app = ElevenLabsKeychain(storage: backend)
        let cli = ElevenLabsKeychain(storage: backend)
        _ = try app.read()
        try app.save("test-menu-key-123456789")
        XCTAssertEqual(try app.read(), "test-menu-key-123456789")
        try cli.save("test-cli-key-1234567890")
        XCTAssertEqual(try app.read(), "test-cli-key-1234567890")
        try cli.remove()
        XCTAssertNil(try app.read())
        XCTAssertFalse(app.containsKey())
        try cli.save("test-new-key-1234567890")
        XCTAssertEqual(try app.read(), "test-new-key-1234567890")
        try app.remove()
        XCTAssertNil(try app.read())
    }

    func testMetadataFailureClearsCacheAndRecoversOnRetry() throws {
        let backend = MemoryKeychain()
        let store = ElevenLabsKeychain(storage: backend)
        _ = try store.read()
        backend.fail(with: errSecInteractionNotAllowed)
        XCTAssertTrue(store.containsKey())
        XCTAssertThrowsError(try store.read())
        backend.fail(with: nil)
        XCTAssertEqual(try store.read(), "test-original-key-123456")
        XCTAssertEqual(backend.readCount, 2)
    }

    func testCancelledMutationPreservesOldKeyAndNeverCachesRejectedReplacement() throws {
        let backend = MemoryKeychain()
        let store = ElevenLabsKeychain(storage: backend)
        _ = try store.read()
        backend.fail(with: errSecUserCanceled)
        XCTAssertThrowsError(try store.save("test-rejected-key-123456"))
        XCTAssertThrowsError(try store.remove())
        backend.fail(with: nil)
        XCTAssertEqual(try store.read(), "test-original-key-123456")
        XCTAssertEqual(backend.readCount, 2)
    }

    func testLegacyLoginKeychainAndIndependentStoreUpdates() throws {
        guard ProcessInfo.processInfo.environment["QUILL_TEST_KEYCHAIN"] == "1" else {
            throw XCTSkip("Set QUILL_TEST_KEYCHAIN=1 for a disposable macOS Keychain test")
        }
        let service = "com.bedeabza.quill.test." + UUID().uuidString
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service, kSecAttrAccount as String: "api-key"]
        var item = query
        item[kSecValueData as String] = Data("test-legacy-key-1234567".utf8)
        XCTAssertEqual(SecItemAdd(item as CFDictionary, nil), errSecSuccess)
        defer { SecItemDelete(query as CFDictionary) }
        let app = ElevenLabsKeychain(service: service)
        let cli = ElevenLabsKeychain(service: service)
        XCTAssertTrue(app.containsKey())
        XCTAssertEqual(try app.read(), "test-legacy-key-1234567")
        XCTAssertEqual(try app.read(), "test-legacy-key-1234567")
        try cli.save("test-replaced-key-1234567")
        XCTAssertEqual(try app.read(), "test-replaced-key-1234567")
        try cli.remove()
        XCTAssertNil(try app.read())
    }

    @MainActor func testMenuReturnsWhileKeychainIsBlocked() async throws {
        let backend = MemoryKeychain()
        let started = expectation(description: "background metadata lookup started")
        let release = DispatchSemaphore(value: 0)
        backend.beforeRevision = {
            XCTAssertFalse(Thread.isMainThread)
            started.fulfill()
            _ = release.wait(timeout: .now() + 5)
        }
        let controller = MenuBarController(keychain: ElevenLabsKeychain(storage: backend))
        controller.menuWillOpen(NSMenu())
        await fulfillment(of: [started], timeout: 2)
        // AppKit can continue handling focus and input before Keychain returns.
        XCTAssertTrue(Thread.isMainThread)
        release.signal()
        XCTAssertEqual(backend.readCount, 0)
    }
}

import Foundation
import Security

/// Serializes login Keychain access and retains an authorized credential only
/// in memory. Call synchronous methods from a background thread, never AppKit.
final class ElevenLabsKeychain: @unchecked Sendable {
    static let shared = ElevenLabsKeychain()
    // The legacy Keychain interaction flag is process-wide. Every operation,
    // including disposable test stores, must use the same queue.
    private static let queue = DispatchQueue(label: "com.bedeabza.quill.keychain", qos: .userInitiated)
    private let storage: any Storage
    private var cached: Credential?

    init(service: String = "com.bedeabza.quill.elevenlabs") {
        storage = LoginKeychain(service: service)
    }

    init(storage: any Storage) { self.storage = storage }

    struct Revision: Equatable, Sendable {
        let created: Date
        let modified: Date
        let generation: Data?
    }

    struct Credential: Sendable {
        let value: String
        let revision: Revision?
    }

    protocol Storage: Sendable {
        func revision() throws -> Revision?
        func read() throws -> Credential?
        func save(_ value: String) throws
        func remove() throws
    }

    struct Failure: Error, CustomStringConvertible {
        let status: OSStatus
        var description: String {
            if status == errSecUserCanceled {
                return "Keychain access was cancelled. Retry when you are ready to authorize Quill."
            }
            return "Could not access the ElevenLabs key in macOS Keychain (status \(status)). Unlock your login keychain and try again."
        }
    }

    /// Metadata only, with interaction disabled for the actual login Keychain.
    func containsKey() -> Bool {
        Self.queue.sync {
            do { return try storage.revision() != nil }
            catch let error as Failure {
                return error.status == errSecInteractionNotAllowed || error.status == errSecAuthFailed
            } catch { return false }
        }
    }

    enum Access: Equatable, Sendable {
        case available, missing, needsAuthorization, failed(String)
    }

    /// Check actual secret access without opening a macOS authorization dialog.
    /// This does not validate the key with ElevenLabs or expose its value.
    func checkAccess() -> Access {
        Self.queue.sync {
            var allowed = DarwinBoolean(false)
            let status = SecKeychainGetUserInteractionAllowed(&allowed)
            guard status == errSecSuccess else { return .failed(Failure(status: status).description) }
            let disabled = SecKeychainSetUserInteractionAllowed(false)
            guard disabled == errSecSuccess else { return .failed(Failure(status: disabled).description) }
            defer { SecKeychainSetUserInteractionAllowed(allowed.boolValue) }
            do {
                guard let credential = try storage.read() else { return .missing }
                _ = try Self.validated(credential.value)
                return .available
            } catch let error as Failure where error.status == errSecInteractionNotAllowed || error.status == errSecAuthFailed {
                return .needsAuthorization
            } catch { return .failed(String(describing: error)) }
        }
    }

    /// Explicit user action: allow macOS to ask for access even when a locked
    /// keychain prevents the usual noninteractive metadata lookup.
    func authorizeAccess() throws -> Bool {
        try Self.queue.sync {
            cached = nil
            guard let credential = try storage.read() else { return false }
            let value = try Self.validated(credential.value)
            cached = Credential(value: value, revision: credential.revision)
            return true
        }
    }

    func read() throws -> String? {
        try Self.queue.sync {
            do {
                guard let revision = try storage.revision() else {
                    cached = nil
                    return nil
                }
                if let cached, cached.revision == revision { return cached.value }
                // Metadata and secret come back from one query so a concurrent
                // CLI update cannot attach a new revision to an old secret.
                cached = nil
                guard let credential = try storage.read() else { return nil }
                let value = try Self.validated(credential.value)
                cached = Credential(value: value, revision: credential.revision)
                return value
            } catch {
                cached = nil
                throw error
            }
        }
    }

    static func validated(_ value: String) throws -> String {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (16...1024).contains(key.utf8.count), key.utf8.allSatisfy({ $0 >= 33 && $0 <= 126 }) else {
            throw TranscriptionFailure("Enter a valid ElevenLabs API key without spaces or line breaks.")
        }
        return key
    }

    func save(_ value: String) throws {
        let key = try Self.validated(value)
        try Self.queue.sync {
            cached = nil
            try storage.save(key)
        }
    }

    func remove() throws {
        try Self.queue.sync {
            cached = nil
            try storage.remove()
        }
    }
}

private struct LoginKeychain: ElevenLabsKeychain.Storage {
    let service: String
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: "api-key", kSecAttrSynchronizable as String: false]
    }

    func revision() throws -> ElevenLabsKeychain.Revision? {
        // LAContext.interactionNotAllowed does not suppress UI for the legacy
        // login Keychain. Restore the process-wide flag before any secret read.
        var allowed = DarwinBoolean(false)
        try check(SecKeychainGetUserInteractionAllowed(&allowed))
        try check(SecKeychainSetUserInteractionAllowed(false))
        defer { SecKeychainSetUserInteractionAllowed(allowed.boolValue) }
        var query = query
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnAttributes as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let attributes = result as? [String: Any], let revision = Self.revision(attributes) else {
            throw ElevenLabsKeychain.Failure(status: errSecDecode)
        }
        return revision
    }

    func read() throws -> ElevenLabsKeychain.Credential? {
        var query = query
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        query[kSecReturnAttributes as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let attributes = result as? [String: Any],
              let data = attributes[kSecValueData as String] as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw ElevenLabsKeychain.Failure(status: errSecDecode)
        }
        return .init(value: value, revision: Self.revision(attributes))
    }

    func save(_ value: String) throws {
        // A generation distinguishes changes even within a single timestamp.
        let attributes: [String: Any] = [kSecValueData as String: Data(value.utf8),
                                        kSecAttrGeneric as String: Data(UUID().uuidString.utf8)]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query.merging(attributes) { _, new in new }
            item[kSecAttrLabel as String] = "Quill: ElevenLabs API key"
            status = SecItemAdd(item as CFDictionary, nil)
        }
        // Update in place preserves the ACL and the old key on failure.
        try check(status)
    }

    func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }

    private static func revision(_ attributes: [String: Any]) -> ElevenLabsKeychain.Revision? {
        guard let created = attributes[kSecAttrCreationDate as String] as? Date,
              let modified = attributes[kSecAttrModificationDate as String] as? Date else { return nil }
        return .init(created: created, modified: modified, generation: attributes[kSecAttrGeneric as String] as? Data)
    }

    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else { throw ElevenLabsKeychain.Failure(status: status) }
    }
}

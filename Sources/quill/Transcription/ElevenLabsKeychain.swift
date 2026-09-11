import Foundation
import LocalAuthentication
import Security

/// Use the macOS login Keychain so Finder, the LaunchAgent, and the bundled
/// CLI share one encrypted credential with the system's normal access control.
struct ElevenLabsKeychain: Sendable {
    static let shared = ElevenLabsKeychain()
    let service: String
    private let account = "api-key"

    init(service: String = "com.bedeabza.quill.elevenlabs") { self.service = service }

    struct Failure: Error, CustomStringConvertible {
        let status: OSStatus
        var description: String { "Could not access the ElevenLabs key in macOS Keychain (status \(status)). Unlock your login keychain and try again." }
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false]
    }

    /// Metadata-only lookup: opening the menu must never prompt for a secret.
    func containsKey() -> Bool {
        var query = query
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnAttributes as String] = true
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess || status == errSecInteractionNotAllowed || status == errSecAuthFailed
    }

    func read() throws -> String? {
        var query = query
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw Failure(status: status) }
        guard let data = result as? Data, let key = String(data: data, encoding: .utf8) else {
            throw Failure(status: errSecDecode)
        }
        return try Self.validated(key)
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
        let data = Data(key.utf8)
        // Update in place to retain Keychain access control and the old key on failure.
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecAttrLabel as String] = "Quill: ElevenLabs API key"
            item[kSecValueData as String] = data
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw Failure(status: status) }
    }

    func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure(status: status) }
    }
}

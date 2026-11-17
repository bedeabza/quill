import Foundation
import Security

struct S3Configuration: Codable, Equatable, Sendable {
    var enabled = false
    var bucket = "neurony-meeting-transcripts"
    var region = "eu-central-1"
    var prefix = "emil-muthu/"
    var accessKeyID = ""

    var destination: String { "s3://\(bucket)/\(prefix)" }
    func sameDestination(as other: Self) -> Bool { bucket == other.bucket && region == other.region && prefix == other.prefix }

    func validated() throws -> Self {
        var value = self
        value.bucket = bucket.trimmingCharacters(in: .whitespacesAndNewlines)
        value.region = region.trimmingCharacters(in: .whitespacesAndNewlines)
        value.prefix = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        value.accessKeyID = accessKeyID.trimmingCharacters(in: .whitespacesAndNewlines)
        // A fixed AWS endpoint, never an arbitrary host supplied with credentials.
        guard value.bucket.range(of: "^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$", options: .regularExpression) != nil else {
            throw TranscriptionFailure("Enter a valid S3 bucket name (letters, numbers and hyphens).")
        }
        guard value.region.range(of: "^[a-z]{2}(-[a-z]+)+-[0-9]+$", options: .regularExpression) != nil else {
            throw TranscriptionFailure("Enter an AWS region, for example eu-central-1.")
        }
        if !value.prefix.hasSuffix("/") { value.prefix += "/" }
        let parts = value.prefix.dropLast().split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              value.prefix.utf8.count <= 512,
              !value.prefix.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !value.prefix.contains("\\") else {
            throw TranscriptionFailure("Enter your assigned folder, for example emil-muthu/. Uploading to the bucket root is not allowed.")
        }
        guard value.accessKeyID.range(of: "^[A-Z0-9]{16,128}$", options: .regularExpression) != nil else {
            throw TranscriptionFailure("Enter a valid AWS access key ID.")
        }
        return value
    }
}

/// The secret never enters config.json, a command line, a log or a transcript.
struct S3SecretStore: Sendable {
    var service = "com.bedeabza.quill.s3"
    private func query(_ accessKeyID: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: accessKeyID]
    }
    func read(_ accessKeyID: String) throws -> String? {
        guard !accessKeyID.isEmpty else { return nil }
        var request = query(accessKeyID)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let secret = String(data: data, encoding: .utf8) else {
            throw TranscriptionFailure("Could not read the S3 secret from Keychain (\(status)). Unlock the login Keychain and try again.")
        }
        return secret
    }
    func save(_ raw: String, for accessKeyID: String) throws {
        let secret = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard secret.utf8.count == 40, secret.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 43 || $0 == 47 || $0 == 61 }) else {
            throw TranscriptionFailure("Enter the 40-character AWS secret access key without spaces or line breaks.")
        }
        let values = [kSecValueData as String: Data(secret.utf8)]
        var status = SecItemUpdate(query(accessKeyID) as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(accessKeyID).merging(values) { _, new in new }
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw TranscriptionFailure("Could not save the S3 secret in Keychain (\(status)).") }
    }
    func remove(_ accessKeyID: String) throws {
        let status = SecItemDelete(query(accessKeyID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw TranscriptionFailure("Could not remove the S3 secret from Keychain (\(status)).")
        }
    }
}

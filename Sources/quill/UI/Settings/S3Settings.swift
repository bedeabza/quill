import Foundation
import Observation
import SwiftUI

@Observable @MainActor
final class S3SettingsModel {
    var configuration: S3Configuration
    private(set) var hasSecret = false
    private(set) var isSaving = false
    private(set) var message: String?
    private(set) var saved = false
    @ObservationIgnored private let configURL: URL
    @ObservationIgnored private let readSecret: @Sendable (String) throws -> String?
    @ObservationIgnored private let saveSecret: @Sendable (String, String) throws -> Void
    @ObservationIgnored private let deleteSecret: @Sendable (String) throws -> Void

    init(configURL: URL = Config.path,
         readSecret: @escaping @Sendable (String) throws -> String? = { try S3SecretStore().read($0) },
         saveSecret: @escaping @Sendable (String, String) throws -> Void = { try S3SecretStore().save($0, for: $1) },
         deleteSecret: @escaping @Sendable (String) throws -> Void = { try S3SecretStore().remove($0) }) {
        self.configURL = configURL; self.readSecret = readSecret; self.saveSecret = saveSecret; self.deleteSecret = deleteSecret
        configuration = Config.s3(at: configURL)
    }
    func checkSecret() async {
        let keyID = configuration.accessKeyID
        do {
            let present = try await Task.detached { [readSecret] in try readSecret(keyID) != nil }.value
            if configuration.accessKeyID == keyID { hasSecret = present }
        } catch { hasSecret = false; message = String(describing: error) }
    }
    @discardableResult func save(secret: String) async -> Bool {
        guard !isSaving else { return false }
        isSaving = true; saved = false; message = nil
        defer { isSaving = false }
        do {
            let value = try configuration.validated()
            try await Task.detached { [readSecret, saveSecret] in
                if !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { try saveSecret(secret, value.accessKeyID) }
                if value.enabled, try readSecret(value.accessKeyID) == nil {
                    throw TranscriptionFailure("Save the secret access key before enabling automatic uploads.")
                }
            }.value
            try Config.setS3(value, at: configURL)
            configuration = value; saved = true
            message = value.enabled ? "Saved. Completed transcriptions will upload to \(value.destination)." : "Saved. Automatic S3 uploads are off."
            await checkSecret()
            return true
        } catch { message = String(describing: error); return false }
    }
    func removeSecret() async {
        guard !isSaving else { return }
        isSaving = true; saved = false; message = nil
        defer { isSaving = false }
        do {
            // Remove the saved account, not an unsaved edited key ID.
            var value = Config.s3(at: configURL); value.enabled = false
            try Config.setS3(value, at: configURL)
            configuration = value
            try await Task.detached { [deleteSecret] in try deleteSecret(value.accessKeyID) }.value
            hasSecret = false; message = "Secret removed. Automatic S3 uploads are off."; saved = true
        } catch { message = String(describing: error) }
    }
}

struct S3SettingsSection: View {
    @State private var model: S3SettingsModel
    @State private var secret = ""

    init(model: S3SettingsModel = S3SettingsModel()) { _model = State(initialValue: model) }

    var body: some View {
        Section {
            Toggle("Upload completed transcripts automatically", isOn: $model.configuration.enabled)
            TextField("Bucket", text: $model.configuration.bucket)
            TextField("AWS region", text: $model.configuration.region)
            TextField("Your folder", text: $model.configuration.prefix)
            TextField("Access key ID", text: $model.configuration.accessKeyID)
            SecureField(model.hasSecret ? "New secret (leave blank to keep saved key)" : "Secret access key", text: $secret)
            LabeledContent("Secret") {
                Label(model.hasSecret ? "Saved in Keychain" : "Not saved", systemImage: model.hasSecret ? "lock.fill" : "key")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("Save S3 Settings") {
                    Task {
                        if await model.save(secret: secret) {
                            secret = ""
                            await S3UploadCoordinator.shared.resumePending(root: Config.resolveRoot(cliOverride: nil))
                        }
                    }
                }
                if model.hasSecret {
                    Button("Remove Saved Secret") { Task { await model.removeSecret(); secret = "" } }
                }
                if model.isSaving { ProgressView().controlSize(.small) }
            }
            if let message = model.message {
                Label(message, systemImage: model.saved ? "checkmark.circle" : "exclamationmark.triangle")
                    .foregroundStyle(model.saved ? Color.secondary : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("S3 transcript archive")
        } footer: {
            Footnote("One Markdown document per meeting, including metadata and saved speaker names. Only text is uploaded. Corrections use a new filename; existing files are never overwritten. Your AWS key must allow uploads into your assigned folder. Use Sync Now to send an existing meeting, or Block S3 Sync to keep a discussion local.")
        }
        .disabled(model.isSaving)
        .task { await model.checkSecret() }
        .onChange(of: model.configuration.accessKeyID) { _, _ in Task { await model.checkSecret() } }
        .onDisappear { secret = "" }
    }
}

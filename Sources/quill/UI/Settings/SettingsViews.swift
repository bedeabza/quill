import AppKit
import SwiftUI

struct TranscriptionSettingsView: View {
    @Bindable var model: SettingsModel
    @State private var key = ""

    var body: some View {
        Form {
            SettingsMessage(model: model)

            Section {
                Picker("Default engine", selection: $model.engine) {
                    ForEach(TranscriptionEngineKind.allCases, id: \.self) { engine in
                        Text(engine.choiceTitle).tag(engine)
                    }
                }
            } footer: {
                Footnote("Parakeet transcribes on this Mac. ElevenLabs uploads the recording’s audio. Applies to the next transcription.")
            }

            Section {
                LabeledContent("API key") { keyState }
                HStack(spacing: 8) {
                    SecureField("API key", text: $key,
                                prompt: Text(model.keyState == .saved ? "Paste a new key to replace it" : "Paste your ElevenLabs API key"))
                        .labelsHidden()
                        .onSubmit(save)
                    Button("Save", action: save)
                        .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isUpdatingKey)
                }
            } header: {
                Text("ElevenLabs")
            } footer: {
                Footnote("Stored in a file only your user account can read.")
            }

            Section {
                Picker("Transcript cleanup", selection: $model.cleanupMode) {
                    ForEach(PostProcessingMode.allCases, id: \.self) { mode in
                        Text(mode.cleanupTitle).tag(mode)
                    }
                }
            } header: {
                Text("After transcription")
            } footer: {
                Footnote("Cleanup sends transcript text to the cloud provider of your signed-in Codex or Claude Code app to fix wording and speaker names. Applies to Parakeet transcripts.")
            }

            Section {
                Picker("Meeting titles", selection: $model.titleMode) {
                    ForEach(PostProcessingMode.allCases, id: \.self) { mode in
                        Text(mode.titlesTitle).tag(mode)
                    }
                }
            } footer: {
                Footnote("Local titles are made on this Mac from transcript keywords. AI titles send transcript excerpts to the selected service; when it’s unavailable, Quill uses a local title.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Transcription")
    }

    @ViewBuilder private var keyState: some View {
        switch model.keyState {
        case .saved:
            HStack(spacing: 10) {
                Label {
                    Text("Saved").foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
                Button("Remove") { Task { await model.removeKey() } }
                    .disabled(model.isUpdatingKey)
            }
        case .notSet:
            Text("Not set").foregroundStyle(.secondary)
        case .problem(let problem):
            Label(problem, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .lineLimit(2)
        }
    }

    private func save() {
        let value = key
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        Task { if await model.saveKey(value) { key = "" } }
    }
}

struct MeetingsSettingsView: View {
    @Bindable var model: SettingsModel
    let appState: AppState
    let navigation: QuillNavigation

    var body: some View {
        Form {
            SettingsMessage(model: model)

            Section {
                Toggle(isOn: $model.automaticMeetingRecording) {
                    Text("Automatic meeting recording")
                    Text("Starts recording when a Zoom, Microsoft Teams, Google Meet or Slack call begins, and stops when it ends.")
                }
                LabeledContent("Status") {
                    HStack(spacing: 8) {
                        HStack(spacing: 6) {
                            Circle().fill(statusColor).frame(width: 8, height: 8)
                            Text(appState.detectionText)
                        }
                        if appState.detectionEnabled && appState.needsMeetingPermission {
                            Button("Open Permissions") { navigation.section = .permissions }
                        }
                    }
                }
                LabeledContent {
                    EmptyView()
                } label: {
                    Text("Keep recording after a meeting ends")
                    Text("Quill stops recording when a detected meeting ends. To keep going once, choose Keep Recording After Meeting Ends in the Quill menu while it records; you then stop that recording yourself.")
                }
            }

            Section("Speakers") {
                Toggle(isOn: $model.voiceMemory) {
                    Text("Remember speaker voices")
                    Text("Learns verified speaker voices locally and recognizes them in later recordings.")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Meetings")
    }

    private var statusColor: Color {
        guard appState.detectionEnabled else { return .secondary }
        return appState.needsMeetingPermission ? .orange : .green
    }
}

struct GeneralSettingsView: View {
    /// The configured recordings folder.
    let root: URL
    let appState: AppState

    var body: some View {
        Form {
            Section("Recordings folder") {
                LabeledContent {
                    Button("Show in Finder") {
                        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(root)
                    }
                } label: {
                    Label {
                        Text(abbreviated(root))
                        Text("New recordings are saved here.")
                    } icon: {
                        Image(systemName: "folder.fill").foregroundStyle(.blue)
                    }
                }
            }

            Section("Advanced") {
                LabeledContent {
                    Button(configExists ? "Open" : "Show Folder", action: openConfig)
                } label: {
                    Text("Configuration file")
                    Text(configExists ? abbreviated(Config.path) : "\(abbreviated(Config.path)) · not created yet")
                }
            }

            Section {
                LabeledContent("Version", value: version)
                LabeledContent {
                    Button("Quit Quill") { appState.quit() }
                } label: {
                    Text("Quill runs in the menu bar")
                    Text("Closing this window keeps it running.")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("General")
    }

    private var configExists: Bool { FileManager.default.fileExists(atPath: Config.path.path) }

    /// Opens the file in its default app; without one, shows the nearest folder that exists.
    private func openConfig() {
        if configExists { NSWorkspace.shared.open(Config.path); return }
        var folder = Config.path.deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: folder.path), folder.pathComponents.count > 1 {
            folder = folder.deletingLastPathComponent()
        }
        NSWorkspace.shared.open(folder)
    }

    private var version: String {
        let info = Bundle.main.infoDictionary
        guard Bundle.main.bundleIdentifier == "com.bedeabza.quill",
              let short = info?["CFBundleShortVersionString"] as? String else { return "Development build" }
        return (info?["CFBundleVersion"] as? String).map { "\(short) (\($0))" } ?? short
    }

    private func abbreviated(_ url: URL) -> String { (url.path as NSString).abbreviatingWithTildeInPath }
}

/// The settings model's last refusal or error, shown at the top of the form.
private struct SettingsMessage: View {
    let model: SettingsModel

    var body: some View {
        if let message = model.message {
            Section {
                Label {
                    Text(message)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
        }
    }
}

struct Footnote: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension TranscriptionEngineKind {
    /// Picker title that says where the audio goes.
    var choiceTitle: String {
        switch self {
        case .parakeet: "Parakeet v3 — On this Mac"
        case .elevenLabs: "ElevenLabs Scribe v2 — Cloud"
        }
    }
}

extension PostProcessingMode {
    var cleanupTitle: String {
        switch self {
        case .off: "Off"
        case .auto: "Automatic"
        case .codex: "Codex (ChatGPT account)"
        case .claude: "Claude Code"
        }
    }

    /// For meeting titles `.off` means titles made on this Mac.
    var titlesTitle: String {
        switch self {
        case .off: "Local titles"
        case .auto: "Automatic AI"
        default: cleanupTitle
        }
    }
}

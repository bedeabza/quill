import SwiftUI

/// Why detection or recording might not work, grouped by what each check is for.
struct PermissionsView: View {
    let model: PermissionsModel
    /// Default engine, for the transcription row's description.
    let engine: TranscriptionEngineKind

    private static let groups: [(String, [PermissionsReport.Item])] = [
        ("Recording", [.microphone, .systemAudio]),
        ("Meetings", [.accessibility, .screen]),
        ("Files and transcription", [.folder, .transcription, .notifications]),
    ]

    var body: some View {
        Form {
            Section { summary }
            ForEach(Self.groups, id: \.0) { title, items in
                Section(title) {
                    ForEach(items.filter { model.items.contains($0) }, id: \.self) { item in
                        PermissionRow(model: model, item: item, info: info(item))
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Permissions")
    }

    private var summary: some View {
        let count = model.attentionCount
        let checking = model.checks.count < model.items.count
        return HStack(alignment: .center, spacing: 12) {
            Image(systemName: count > 0 ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 22))
                .foregroundStyle(count > 0 ? .orange : .green)
                .opacity(checking && count == 0 ? 0 : 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(count > 0 ? "\(count) \(count == 1 ? "item needs" : "items need") attention"
                     : checking ? "Checking…" : "Quill is ready")
                    .font(.headline)
                Text("Checks apply to this copy of Quill. Refreshing does not record or upload anything.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Check Again") { model.refresh() }
        }
        .padding(.vertical, 4)
    }

    private func info(_ item: PermissionsReport.Item) -> PermissionInfo {
        switch item {
        case .microphone:
            PermissionInfo(title: "Microphone", detail: "Records your side of the meeting.", symbol: "mic.fill", color: .orange, ok: "Allowed")
        case .systemAudio:
            PermissionInfo(title: "System audio", detail: "Records the other participants.", symbol: "speaker.wave.2.fill", color: .gray, ok: "Allowed")
        case .accessibility:
            PermissionInfo(title: "Accessibility", detail: "Meeting detection and participant names.", symbol: "accessibility", color: .blue, ok: "Allowed")
        case .screen:
            PermissionInfo(title: "Screen Recording", detail: "Zoom speaker indicators. May need a Quill restart.",
                           symbol: "rectangle.dashed.badge.record", color: .purple, ok: "Allowed")
        case .folder, .recording:
            PermissionInfo(title: "Recordings folder", detail: (model.root.path as NSString).abbreviatingWithTildeInPath,
                           symbol: "folder.fill", color: .cyan, ok: "Writable")
        case .transcription:
            PermissionInfo(title: "Transcription",
                           detail: engine == .elevenLabs ? "ElevenLabs Scribe v2 transcribes in the cloud." : "Parakeet v3 runs on this Mac.",
                           symbol: "text.quote", color: .indigo, ok: "Ready")
        case .notifications:
            PermissionInfo(title: "Notifications", detail: "Recording and transcription alerts.", symbol: "bell.badge.fill", color: .red, ok: "Allowed")
        }
    }
}

private struct PermissionInfo {
    let title: String
    let detail: String
    let symbol: String
    let color: Color
    /// State text when the check passes.
    let ok: String
}

private struct PermissionRow: View {
    let model: PermissionsModel
    let item: PermissionsReport.Item
    let info: PermissionInfo

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: info.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(info.color.gradient, in: .rect(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                Text(info.title)
                Text(info.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            state
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .frame(maxWidth: 300, alignment: .trailing)
            if let action = model.actionTitle(item) {
                Button(action) { model.perform(item) }
            }
        }
        .help(check?.remediation ?? "")
    }

    private var check: Check? { model.checks[item] }

    @ViewBuilder private var state: some View {
        switch check?.status {
        case nil:
            ProgressView().controlSize(.small)
        case .ok:
            Label {
                Text(info.ok).foregroundStyle(.secondary)
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
        case .warn(let message) where item == .systemAudio:
            // No check can clear it, so it is informational, not a warning.
            Label(sentence(message), systemImage: "questionmark.circle")
                .foregroundStyle(.secondary)
        case .warn(let message):
            Label(sentence(message), systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .fail(let message):
            Label(sentence(message), systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
        }
    }

    /// Check messages are often lower case ("denied"); state labels start with a capital.
    private func sentence(_ text: String) -> String { text.prefix(1).uppercased() + text.dropFirst() }
}

import AppKit
import SwiftUI

/// Recordings: a day-grouped list on the left, the selected meeting's
/// transcript on the right.
struct RecordingsView: View {
    @Bindable var model: RecordingsModel
    @State private var regenerating = false

    var body: some View {
        content
            .navigationTitle("Recordings")
            .searchable(text: $model.query, placement: .toolbar, prompt: "Search titles and people")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Show in Finder", systemImage: "folder") {
                        if let entry = model.selectedEntry { model.showInFinder(entry) }
                    }
                    .help("Show this recording’s folder in Finder")
                    .disabled(model.selectedEntry == nil)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Regenerate…") { regenerating = true }
                        .help("Transcribe this recording again")
                        .disabled(!model.canRegenerate)
                }
            }
            .sheet(isPresented: $regenerating) {
                if let entry = model.selectedEntry { RegenerateSheet(model: model, entry: entry) }
            }
    }

    @ViewBuilder private var content: some View {
        if let error = model.loadError {
            ContentUnavailableView {
                Label("Can’t Read This Folder", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                FolderActions(model: model)
            }
        } else if !model.hasLoaded {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.entries.isEmpty {
            ContentUnavailableView {
                Label(model.isDefaultRoot ? "No Recordings Yet" : "No Recordings Here", systemImage: "waveform")
            } description: {
                Text(model.isDefaultRoot
                     ? "Start a recording from the Quill menu in the menu bar, or turn on Automatic Meeting Recording."
                     : "“\(model.root.lastPathComponent)” has no recordings.")
            } actions: {
                FolderActions(model: model)
            }
        } else {
            HStack(spacing: 0) {
                RecordingList(model: model)
                    .frame(width: 300)
                Divider()
                if let entry = model.selectedEntry {
                    RecordingDetail(model: model, entry: entry, regenerate: $regenerating)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }
}

/// Ways out of an empty or unreadable folder.
private struct FolderActions: View {
    let model: RecordingsModel

    var body: some View {
        HStack {
            if !model.isDefaultRoot {
                Button("Show Default Folder") { model.useDefaultRoot() }
            }
            Button("Browse Another Folder…") { chooseFolder(model) }
        }
    }
}

/// Opens a folder of recordings, or one recording, in the list.
@MainActor func chooseFolder(_ model: RecordingsModel) {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.directoryURL = model.root
    panel.prompt = "Browse"
    panel.message = "Choose a folder of recordings, or a single recording."
    let finish = { (response: NSApplication.ModalResponse) in
        if response == .OK, let url = panel.url { model.browse(url) }
    }
    if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: finish) } else { finish(panel.runModal()) }
}

// MARK: - List

private struct RecordingList: View {
    @Bindable var model: RecordingsModel

    var body: some View {
        List(selection: $model.selection) {
            ForEach(model.sections) { section in
                Section(section.title) {
                    ForEach(section.entries, id: \.directory) { entry in
                        RecordingRow(entry: entry, status: model.status(of: entry))
                            .tag(entry.directory)
                            .onAppear { model.rowAppeared(entry) }
                            .onDisappear { model.rowDisappeared(entry) }
                    }
                }
            }
        }
        .listStyle(.inset)
        .overlay {
            if model.sections.isEmpty { ContentUnavailableView.search(text: model.query) }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { folderBar }
    }

    /// Browsing another folder is rare, so it lives in a quiet footer that also
    /// says which folder the list shows.
    private var folderBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 6) {
                Menu {
                    Toggle("\(model.defaultRoot.lastPathComponent) (default)", isOn: Binding(
                        get: { model.isDefaultRoot }, set: { if $0 { model.useDefaultRoot() } }))
                    if !model.isDefaultRoot {
                        Toggle(model.root.lastPathComponent, isOn: .constant(true))
                    }
                    Divider()
                    Button("Browse Another Folder…") { chooseFolder(model) }
                } label: {
                    Label(model.root.lastPathComponent, systemImage: "folder")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help(model.root.path)
                Spacer()
                Text(count)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .font(.callout)
            .controlSize(.small)
            .padding(.horizontal, 12)
            .frame(height: 30)
        }
        .background(.bar)
    }

    private var count: String {
        let total = model.entries.count
        let noun = total == 1 ? "recording" : "recordings"
        guard !model.query.trimmingCharacters(in: .whitespaces).isEmpty else { return "\(total) \(noun)" }
        return "\(model.sections.reduce(0) { $0 + $1.entries.count }) of \(total)"
    }
}

private struct RecordingRow: View {
    let entry: RecordingEntry
    let status: RecordingStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(entry.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(entry.startedAt.formatted(date: .omitted, time: .shortened))
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(([RecordingFormat.duration(entry.duration)].compactMap { $0 } + [RecordingFormat.people(entry.participants)])
                        .joined(separator: " · "))
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                StatusTag(status: status)
            }
            .font(.callout)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 2)
    }
}

/// Ready is the normal state and shows nothing; everything else is labelled.
private struct StatusTag: View {
    let status: RecordingStatus
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        switch status {
        case .ready: EmptyView()
        case .transcribing: tag("Transcribing", "waveform", .blue)
        case .queued: tag("Queued", "clock", .secondary)
        case .failed: tag("Failed", "exclamationmark.triangle.fill", .red)
        case .notTranscribed: tag("Not transcribed", "minus.circle", .secondary)
        case .unfinished: tag("Unfinished", "exclamationmark.circle", .secondary)
        }
    }

    private func tag(_ text: String, _ symbol: String, _ style: some ShapeStyle) -> some View {
        Label(text, systemImage: symbol)
            .labelStyle(.titleAndIcon)
            .font(.caption.weight(.medium))
            .foregroundStyle(prominence == .increased ? AnyShapeStyle(.primary) : AnyShapeStyle(style))
            .imageScale(.small)
            .fixedSize()
    }
}

// MARK: - Detail

private struct RecordingDetail: View {
    @Bindable var model: RecordingsModel
    let entry: RecordingEntry
    @Binding var regenerate: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.bottom, 18)
                if let banner {
                    banner.padding(.bottom, 18)
                }
                transcriptBar
                    .padding(.bottom, 14)
                transcript
            }
            .padding(.horizontal, 28)
            .padding(.top, 22)
            .padding(.bottom, 28)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Each recording opens at the top; refreshes of the same one keep the position.
        .id(entry.directory)
    }

    private var status: RecordingStatus { model.status(of: entry) }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(entry.title)
                    .font(.system(size: 22, weight: .bold))
                    .textSelection(.enabled)
                    .help(entry.originalTitle.map { $0 == entry.title ? "" : "Original title: \($0)" } ?? "")
                titleButton
            }
            VStack(alignment: .leading, spacing: 5) {
                Label(RecordingFormat.when(entry), systemImage: "calendar")
                Label(entry.participants.isEmpty ? "No participants recorded" : entry.participants.joined(separator: ", "),
                      systemImage: "person.2")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        }
    }

    @ViewBuilder private var titleButton: some View {
        if model.isGeneratingTitle(entry) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Generating title…")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        } else {
            Button(entry.titleSource == nil ? "Generate Title" : "Refresh Title", systemImage: "sparkles") {
                model.generateTitle(entry)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .disabled(!model.canGenerateTitle(entry))
            .help("Creates a title from the meeting content. The original title is kept.")
        }
    }

    /// The tinted line above the transcript: progress, queue position, failures.
    private var banner: Banner? {
        let failed = model.regenerateError != nil
        let message = model.selectedMessage
        if model.isEnqueuing { return Banner(tint: .blue, symbol: nil, text: message ?? "") }
        switch status {
        case .ready:
            return message.map { Banner(tint: failed ? .red : .secondary,
                                        symbol: failed ? "exclamationmark.triangle.fill" : "info.circle", text: $0) }
        case .transcribing:
            return Banner(tint: .blue, symbol: nil, text: message ?? "Transcribing…")
        case .queued:
            return Banner(tint: .secondary, symbol: "clock", text: message ?? "Queued.")
        case .failed:
            return Banner(tint: .red, symbol: "exclamationmark.triangle.fill", text: message ?? "Transcription failed.",
                          action: model.canRegenerate ? (entry.hasTranscript ? "Regenerate…" : "Transcribe…", { regenerate = true }) : nil)
        case .notTranscribed:
            return Banner(tint: failed ? .red : .secondary, symbol: failed ? "exclamationmark.triangle.fill" : "minus.circle",
                          text: message ?? "This recording hasn’t been transcribed.",
                          action: model.canRegenerate ? ("Transcribe…", { regenerate = true }) : nil)
        case .unfinished:
            return Banner(tint: .secondary, symbol: "exclamationmark.circle", text: message ?? "This recording is unfinished.")
        }
    }

    private var transcriptBar: some View {
        HStack {
            Text("Transcript")
                .font(.headline)
            Spacer()
            if entry.hasTranscript {
                Picker("Speaker labels", selection: named) {
                    Text("Original").tag(false)
                    Text("With names").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .disabled(!model.canShowNamed)
                .help(model.canShowNamed ? "Show speaker names matched from the meeting"
                                         : "No named transcript is available for this recording")
            }
        }
        .frame(minHeight: 24)
    }

    private var named: Binding<Bool> {
        Binding(get: { model.named }, set: { if !$0 || model.canShowNamed { model.named = $0 } })
    }

    @ViewBuilder private var transcript: some View {
        if !entry.hasTranscript {
            placeholder(status == .transcribing || status == .queued || model.isEnqueuing
                        ? "The transcript appears here when it’s ready." : "No transcript yet.")
        } else {
            switch model.transcript {
            case .turns(let turns):
                let colors = RecordingFormat.colors(turns)
                // Lazy, so meetings of several hours scroll smoothly.
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(turns) { turn in
                        TurnView(turn: turn, color: model.named ? colors[turn.speaker] ?? .primary : .secondary)
                    }
                }
                .textSelection(.enabled)
            case .text(let text):
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(text.components(separatedBy: "\n\n").enumerated()), id: \.offset) { paragraph in
                        Text(paragraph.element)
                            .font(.system(size: 14))
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .textSelection(.enabled)
            case .empty(let message):
                placeholder(message)
            case nil:
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, minHeight: 160)
            }
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, minHeight: 160)
    }
}

private struct TurnView: View {
    let turn: TranscriptTurn
    let color: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(RecordingFormat.clock(turn.start))
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .frame(width: 62, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text(turn.speaker)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(color)
                Text(turn.text)
                    .font(.system(size: 14))
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct Banner: View {
    let tint: Color
    /// nil shows a spinner.
    let symbol: String?
    let text: String
    var action: (String, () -> Void)? = nil

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            if let symbol {
                Image(systemName: symbol)
                    .foregroundStyle(tint == .secondary ? Color.secondary : tint)
                    .font(.system(size: 14))
            } else {
                ProgressView().controlSize(.small)
            }
            Text(text)
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let action {
                Button(action.0, action: action.1)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background((tint == .secondary ? Color.primary : tint).opacity(0.07), in: .rect(cornerRadius: 8))
    }
}

/// Display strings for recordings.
enum RecordingFormat {
    /// "52 min", "1 h 10 min"; nil when unknown.
    static func duration(_ seconds: Int?) -> String? {
        guard let seconds, seconds >= 0 else { return nil }
        if seconds < 60 { return "\(seconds) s" }
        let minutes = Int((Double(seconds) / 60).rounded())
        guard minutes >= 60 else { return "\(minutes) min" }
        return minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60) min"
    }

    /// First names, at most three: "Dragos, Emil, Ioana +2".
    static func people(_ names: [String]) -> String {
        guard !names.isEmpty else { return "No participants" }
        let first = names.map { $0.split(separator: " ").first.map(String.init) ?? $0 }
        return first.count > 3 ? first.prefix(3).joined(separator: ", ") + " +\(first.count - 3)" : first.joined(separator: ", ")
    }

    /// "Wednesday 4 November 2026 · 10:00–10:52 · 52 min".
    static func when(_ entry: RecordingEntry) -> String {
        let start = entry.startedAt
        var range = start.formatted(date: .omitted, time: .shortened)
        if let end = entry.endedAt { range += "–" + end.formatted(date: .omitted, time: .shortened) }
        return [start.formatted(.dateTime.weekday(.wide).day().month(.wide).year()), range, duration(entry.duration)]
            .compactMap { $0 }.joined(separator: " · ")
    }

    /// "00:01:12".
    static func clock(_ seconds: Int) -> String {
        String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }

    /// A colour per speaker in order of first appearance, so the people in one
    /// meeting stay distinct.
    static func colors(_ turns: [TranscriptTurn]) -> [String: Color] {
        let palette: [Color] = [.blue, .orange, .green, .purple, .pink, .teal, .indigo, .brown]
        var colors: [String: Color] = [:]
        for turn in turns where colors[turn.speaker] == nil {
            colors[turn.speaker] = palette[colors.count % palette.count]
        }
        return colors
    }
}

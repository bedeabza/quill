import AppKit
import SwiftUI
import UniformTypeIdentifiers

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
                    if let entry = model.selectedEntry, entry.hasTranscript || entry.s3Blocked {
                        S3StatusTag(entry: entry, enabled: model.s3Enabled)
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Export HTML…", systemImage: "square.and.arrow.up") {
                        if let entry = model.selectedEntry { exportHTML(entry, model: model) }
                    }
                    .help("Export the displayed discussion, title and speaker names as an HTML file")
                    .disabled(model.selectedEntry?.hasTranscript != true || model.isExportingHTML)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Show in Finder", systemImage: "folder") {
                        if let entry = model.selectedEntry { model.showInFinder(entry) }
                    }
                    .help("Show this recording’s folder in Finder")
                    .disabled(model.selectedEntry == nil)
                }
            }
            .sheet(isPresented: $regenerating) {
                if let entry = model.selectedEntry { RegenerateSheet(model: model, entry: entry) }
            }
            .onChange(of: regenerating) { _, opening in if opening { model.prepareRegenerate() } }
            // A sheet without its recording has nothing to regenerate and no way to cancel.
            .onChange(of: model.selectedEntry?.directory) { _, directory in if directory == nil { regenerating = false } }
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
                RecordingList(model: model, regenerate: regenerate)
                    .frame(width: 300)
                Divider()
                if let entry = model.selectedEntry {
                    RecordingDetail(model: model, entry: entry, regenerate: regenerate)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    /// The sheet works on the selection, so a row's menu selects its recording first.
    private func regenerate(_ entry: RecordingEntry) {
        model.selection = entry.directory
        regenerating = true
    }
}

/// A recording's actions, in its row's context menu and its detail header's menu.
private struct RecordingActions: View {
    let model: RecordingsModel
    let entry: RecordingEntry
    let regenerate: (RecordingEntry) -> Void

    var body: some View {
        Button("Show in Finder") { model.showInFinder(entry) }
        Button("Export HTML…") { exportHTML(entry, model: model) }
            .disabled(!entry.hasTranscript || model.isExportingHTML)
        Button(entry.hasTranscript ? "Regenerate…" : "Transcribe…") { regenerate(entry) }
            .disabled(!model.canRegenerate(entry))
        if model.selection == entry.directory, model.speakerNames?.rows.isEmpty == false {
            Button("Name Speakers…") { model.openSpeakerNameEditor() }
                .disabled(model.showsSpeakerNames)
        }
        Divider()
        Button(entry.s3Blocked ? "Unblock & Sync Now" : "Sync Now to S3") { model.uploadToS3(entry) }
            .disabled(!model.canSyncToS3(entry))
        Button(entry.s3Blocked ? "Allow Automatic S3 Sync" : "Block S3 Sync") { model.setS3Blocked(!entry.s3Blocked, for: entry) }
            .disabled(model.s3Actions.contains(entry.directory))
        Divider()
        Button("Delete…") { confirmDelete(entry, model: model) }
    }
}

/// The export is captured before presenting the save sheet; changing selection
/// or background title/transcription work cannot alter what will be written.
@MainActor func exportHTML(_ entry: RecordingEntry, model: RecordingsModel) {
    guard entry.hasTranscript, !model.isExportingHTML else { return }
    model.isExportingHTML = true
    Task {
        defer { model.isExportingHTML = false }
        do {
            let document = try await model.htmlExport(for: entry)
            let panel = NSSavePanel()
            panel.title = "Export Discussion as HTML"
            panel.prompt = "Export"
            panel.message = "Includes the displayed title, transcript and speaker names, including unsaved name edits. Recording files stay unchanged."
            panel.allowedContentTypes = [.html]
            panel.allowsOtherFileTypes = false
            panel.canCreateDirectories = true
            panel.isExtensionHidden = false
            panel.nameFieldStringValue = document.suggestedFilename
            NSApp.activate(ignoringOtherApps: true)
            let result: NSApplication.ModalResponse = await withCheckedContinuation { continuation in
                if let window = NSApp.keyWindow {
                    panel.beginSheetModal(for: window) { continuation.resume(returning: $0) }
                } else {
                    panel.begin { continuation.resume(returning: $0) }
                }
            }
            guard result == .OK, let destination = panel.url else { return }
            try await Task.detached(priority: .userInitiated) { try document.write(to: destination) }.value
            model.didExportHTML(destination, for: entry)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn’t Export This Discussion"
            alert.informativeText = (error as? TranscriptionFailure)?.description ?? error.localizedDescription
            if let window = NSApp.keyWindow { _ = await alert.beginSheetModal(for: window) }
            else { alert.runModal() }
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

/// Asks before moving a recording's folder to the Trash; explains a refusal.
@MainActor func confirmDelete(_ entry: RecordingEntry, model: RecordingsModel) {
    func present(_ alert: NSAlert, _ finish: @escaping (NSApplication.ModalResponse) -> Void = { _ in }) {
        // A right-click does not activate Quill, so there may be no key window yet.
        NSApp.activate(ignoringOtherApps: true)
        let window = NSApp.keyWindow ?? NSApp.windows.first { $0.windowController is QuillWindowController && $0.isVisible }
        if let window { alert.beginSheetModal(for: window, completionHandler: finish) } else { finish(alert.runModal()) }
    }
    func refuse(_ reason: String) {
        let alert = NSAlert()
        alert.messageText = "Can’t Delete “\(entry.title)”"
        alert.informativeText = reason
        present(alert)
    }
    if let refusal = model.deletionRefusal(entry) { return refuse(refusal) }
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "Delete “\(entry.title)”?"
    alert.informativeText = RecordingFormat.when(entry) + "\n\nAll of its files move to the Trash: audio, transcripts, "
        + "cached ElevenLabs responses and backups. You can put it back from the Trash."
    // Cancel is the default, so Return cancels; giving it Return takes Escape
    // away from it, so a key monitor keeps Escape cancelling too.
    let cancel = alert.addButton(withTitle: "Cancel")
    cancel.keyEquivalent = "\r"
    alert.addButton(withTitle: "Delete").hasDestructiveAction = true
    let escape = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
        guard event.keyCode == 53, event.window === alert.window else { return event }
        cancel.performClick(nil)
        return nil
    }
    present(alert) { response in
        if let escape { NSEvent.removeMonitor(escape) }
        guard response == .alertSecondButtonReturn else { return }
        Task { if let failure = await model.delete(entry) { refuse(failure) } }
    }
}

// MARK: - List

private struct RecordingList: View {
    @Bindable var model: RecordingsModel
    let regenerate: (RecordingEntry) -> Void

    var body: some View {
        List(selection: $model.selection) {
            ForEach(model.sections) { section in
                Section(section.title) {
                    ForEach(section.entries, id: \.directory) { entry in
                        RecordingRow(entry: entry, status: model.status(of: entry), s3Enabled: model.s3Enabled)
                            .tag(entry.directory)
                            .onAppear { model.rowAppeared(entry) }
                            .onDisappear { model.rowDisappeared(entry) }
                    }
                }
            }
        }
        .listStyle(.inset)
        .contextMenu(forSelectionType: URL.self) { selected in
            if let entry = selected.first.flatMap(entry) {
                RecordingActions(model: model, entry: entry, regenerate: regenerate)
            }
        }
        .onDeleteCommand { if let entry = model.selectedEntry { confirmDelete(entry, model: model) } }
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

    private func entry(_ directory: URL) -> RecordingEntry? { model.entries.first { $0.directory == directory } }

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
    let s3Enabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(entry.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(3)
                    .help(entry.title)
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
            if entry.hasTranscript || entry.s3Blocked { S3StatusTag(entry: entry, enabled: s3Enabled) }
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
    let regenerate: (RecordingEntry) -> Void
    @State private var signingInClaude = false
    @State private var following = true
    @State private var visibleTurns: Set<Int> = []
    @FocusState private var transcriptFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                if case .turns(let turns) = model.transcript {
                    speakerNavigation(turns)
                }
                if model.showsSpeakerNames, let state = model.speakerNames {
                    SpeakerNamesForm(model: model, state: state, colors: turnColors)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 18)
            .padding(.bottom, 12)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        header
                        if let banner { banner }
                        transcriptBar
                        transcript
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 18)
                    .frame(maxWidth: 720, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onScrollPhaseChange { _, phase in if phase == .interacting { following = false } }
                .onChange(of: model.player.activeTurn) { _, turn in
                    guard following, let turn, !visibleTurns.contains(turn) else { return }
                    withAnimation { proxy.scrollTo(turn, anchor: UnitPoint(x: 0.5, y: 0.2)) }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if model.player.directory == entry.directory {
                        PlayerBar(player: model.player, following: following) {
                            following = true
                            if let turn = model.player.activeTurn { withAnimation { proxy.scrollTo(turn, anchor: UnitPoint(x: 0.5, y: 0.2)) } }
                        }
                    }
                }
                .onChange(of: model.speakerTurnRequest) { _, _ in
                    following = false
                    if let target = model.speakerTurnTarget {
                        withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(target, anchor: .top) }
                    }
                }
            }
            // ScrollViewReader otherwise contributes the lazy transcript's
            // full ideal height to NavigationSplitView's column minimums.
            .frame(minHeight: 0, maxHeight: .infinity)
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        // Each recording opens at the top; refreshes of the same one keep the position.
        .id(entry.directory)
        .sheet(isPresented: $signingInClaude) { ClaudeSignInSheet() }
    }

    private func play(_ turn: TranscriptTurn) {
        following = true
        transcriptFocused = true
        model.play(from: turn)
    }

    private var status: RecordingStatus { model.status(of: entry) }

    private var turnColors: [String: Color] {
        if case .turns(let turns) = model.transcript { return RecordingFormat.colors(turns) }
        return [:]
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(entry.title)
                    .font(.system(size: 22, weight: .bold))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .help(entry.originalTitle.map { $0 == entry.title ? "" : "Original title: \($0)" } ?? "")
                Spacer(minLength: 0)
                Menu {
                    RecordingActions(model: model, entry: entry, regenerate: regenerate)
                } label: {
                    Label("Actions", systemImage: "ellipsis.circle")
                        .labelStyle(.iconOnly)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Regenerate or delete this recording")
            }
            HStack(spacing: 10) {
                titleButton
                if entry.titleSource == "local" {
                    Text(entry.titleStatus == "ai_failed" ? "Local title · AI generation failed"
                         : entry.titleStatus == "ai_unavailable" ? "Local title · AI unavailable" : "Local title")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("AI titles use the helper chosen in Transcription settings. Check that helper’s sign-in if generation fails.")
                    if Config.recordingTitleMode() == .claude, ["ai_failed", "ai_unavailable"].contains(entry.titleStatus ?? "") {
                        Button("Sign In to Claude…") { signingInClaude = true }
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                Label(RecordingFormat.when(entry), systemImage: "calendar")
                Label(entry.participants.isEmpty ? "No participants recorded" : entry.participants.joined(separator: ", "),
                      systemImage: "person.2")
                if let notice = model.microphoneNotice {
                    Label(notice, systemImage: "mic.slash")
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            VStack(alignment: .leading, spacing: 8) {
                S3StatusTag(entry: entry, enabled: model.s3Enabled)
                HStack {
                    Button(entry.s3Blocked ? "Allow Automatic Sync" : "Block S3 Sync") { model.setS3Blocked(!entry.s3Blocked, for: entry) }
                        .disabled(model.s3Actions.contains(entry.directory))
                    Spacer()
                    if model.s3Actions.contains(entry.directory) { ProgressView().controlSize(.small) }
                    Button(entry.s3Blocked ? "Unblock & Sync Now" : "Sync Now") { model.uploadToS3(entry) }
                        .disabled(!model.canSyncToS3(entry))
                        .help("Upload a new Markdown copy of this discussion, even if it was already synced or automatic syncing is off.")
                }
                if entry.s3Blocked {
                    Text("Automatic uploads and retries are blocked for this discussion. Files already sent to S3 are kept.")
                        .font(.caption)
                }
                if let upload = entry.s3Upload {
                    Text(upload.location).font(.caption).textSelection(.enabled)
                    if let date = upload.uploadedAt { Text("Uploaded \(date.formatted(date: .abbreviated, time: .shortened))").font(.caption) }
                    if let message = upload.message { Text(message).font(.callout).foregroundStyle(.orange) }
                }
                if let error = model.s3Errors[entry.directory] { Text(error).font(.callout).foregroundStyle(.orange) }
                if !model.s3Enabled { Text("Automatic sync is off. Sync Now sends just this discussion using your saved S3 settings.").font(.caption) }
                if !entry.hasTranscript { Text("Sync Now becomes available after transcription.").font(.caption) }
                if model.hasSpeakerChanges { Text("Apply Names before syncing your changes.").font(.caption) }
            }
            .padding(12)
            .background(Color.primary.opacity(0.04), in: .rect(cornerRadius: 8))
        }
    }

    /// Outside the transcript's scroll view, so the voice controls stay put.
    private func speakerNavigation(_ turns: [TranscriptTurn]) -> some View {
        var seen: Set<String> = []
        let voices = turns.filter { seen.insert($0.navigationID).inserted }
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Speakers").font(.headline)
                Spacer()
                if model.speakerNames?.rows.isEmpty == false {
                    Button(model.showsSpeakerNames ? "Hide Name Editor" : "Edit Names") {
                        if model.showsSpeakerNames { model.speakerNameEditorCollapsed = true }
                        else { model.openSpeakerNameEditor() }
                    }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .disabled(model.isApplyingSpeakerNames)
                }
            }
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(voices) { turn in
                    let identity = turn.navigationID
                    let label = turn.speakerID.map(SpeakerNames.label) ?? turn.speaker
                    let name = model.displayName(for: turn)
                    Button { model.nextSpeakerTurn(identity) } label: {
                        HStack(spacing: 6) {
                            Circle().fill(turnColors[identity] ?? .secondary).frame(width: 7, height: 7)
                            Text(name == label ? label : "\(label) · \(name)")
                                .lineLimit(1)
                                .multilineTextAlignment(.leading)
                            Image(systemName: "arrow.down").font(.caption2)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Color.primary.opacity(0.05), in: .rect(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .font(.callout)
                    .help("Go to the next turn by \(name). Starts at the first turn and repeats after the last.")
                    .accessibilityLabel("Next turn: \(label), \(name)")
                    }
                }
            }
            .scrollIndicators(.hidden)
            .frame(height: 32)
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
                          action: model.canRegenerate ? (entry.hasTranscript ? "Regenerate…" : "Transcribe…", { regenerate(entry) }) : nil)
        case .notTranscribed:
            return Banner(tint: failed ? .red : .secondary, symbol: failed ? "exclamationmark.triangle.fill" : "minus.circle",
                          text: message ?? "This recording hasn’t been transcribed.",
                          action: model.canRegenerate ? ("Transcribe…", { regenerate(entry) }) : nil)
        case .unfinished:
            return Banner(tint: .secondary, symbol: "exclamationmark.circle", text: message ?? "This recording is unfinished.")
        }
    }

    private var transcriptBar: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Transcript")
                .font(.headline)
            Spacer(minLength: 8)
            if case .unavailable(let reason) = model.playback, case .turns = model.transcript {
                Label("No audio to play", systemImage: "speaker.slash")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .help(reason)
            }
        }
        .frame(minHeight: 24)
    }

    @ViewBuilder private var transcript: some View {
        if !entry.hasTranscript {
            placeholder(status == .transcribing || status == .queued || model.isEnqueuing
                        ? "The transcript appears here when it’s ready." : "No transcript yet.")
        } else {
            switch model.transcript {
            case .turns(let turns):
                let colors = RecordingFormat.colors(turns)
                let playable = if case .tracks = model.playback { true } else { false }
                let active = model.player.directory == entry.directory ? model.player.activeTurn : nil
                // Lazy, so meetings of several hours scroll smoothly.
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(turns) { turn in
                        TurnView(turn: turn, name: model.displayName(for: turn), color: colors[turn.navigationID] ?? .primary, highlighted: model.speakerTurnTarget == turn.id, isActive: turn.id == active,
                                 play: playable ? { play(turn) } : nil)
                            .id(turn.id)
                            .onScrollVisibilityChange(threshold: 0.5) { visible in
                                if visible { visibleTurns.insert(turn.id) } else { visibleTurns.remove(turn.id) }
                            }
                    }
                }
                .textSelection(.enabled)
                // Space plays and pauses once a turn was played. Only the turns take
                // focus, so the search field and the speaker pickers keep Space.
                .focusable()
                .focusEffectDisabled()
                .focused($transcriptFocused)
                .onKeyPress(.space) {
                    guard model.player.directory == entry.directory, model.player.toggle() else { return .ignored }
                    return .handled
                }
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

/// "Speaker 1 is [name]" for each voice of a Scribe transcript, pre-selected
/// with confirmed names or accepted evidence. Apply preserves the original.
private struct SpeakerNamesForm: View {
    @Bindable var model: RecordingsModel
    let state: SpeakerNames.State
    /// Transcript colours by displayed speaker, so each row matches its turns.
    let colors: [String: Color]
    @State private var columns = 1
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Name each voice. Link voices only when you know they are the same person. A microphone can contain several people.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // Only the editor's overflow scrolls when there are many voices;
            // the navigation controls above it remain fixed and reachable.
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), alignment: .leading)], alignment: .leading, spacing: 8) {
                    ForEach(state.rows, id: \.speaker) { row in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Circle().fill(colors[row.personID ?? row.speaker] ?? .secondary).frame(width: 7, height: 7)
                                Text(row.label).font(.callout.weight(.medium))
                                Text(caption(row)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            HStack(spacing: 4) {
                                TextField("Type a name", text: binding(row))
                                    .textFieldStyle(.roundedBorder)
                                    .accessibilityLabel("Name for \(row.label)")
                                Menu {
                                    ForEach(availableNames, id: \.self) { name in
                                        Button(name) { model.setSpeakerName(name, for: row.speaker) }
                                    }
                                    Divider()
                                    Button("Unknown") { model.setSpeakerName("", for: row.speaker) }
                                    Divider()
                                    Menu("Same person as…") {
                                        ForEach(state.rows.filter { model.speakerGroup(for: $0) != model.speakerGroup(for: row) }, id: \.speaker) { other in
                                            Button("\(other.label) · \(model.speakerName(for: other).isEmpty ? "Unknown" : model.speakerName(for: other))") {
                                                model.linkSpeaker(row, to: other)
                                            }
                                        }
                                    }
                                    if state.rows.filter({ model.speakerGroup(for: $0) == model.speakerGroup(for: row) }).count > 1 {
                                        Button("Separate this voice") { model.separateSpeaker(row) }
                                    }
                                } label: {
                                    Image(systemName: "person.crop.circle.badge.checkmark")
                                }
                                .menuStyle(.borderlessButton)
                                .fixedSize()
                                .help("Choose a participant for \(row.label)")
                            }
                        }
                    }
                }
            }
            .frame(height: min(180, CGFloat((state.rows.count + columns - 1) / columns) * 54))
            .onGeometryChange(for: Int.self) { geometry in
                max(1, Int((geometry.size.width + 8) / 218))
            } action: { columns = $0 }
            if !state.observedNames.isEmpty {
                DisclosureGroup("Participant aliases") {
                    Text("Choose a main name for alternate roster names. Voice links are a separate choice above.")
                        .font(.caption).foregroundStyle(.secondary)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(state.observedNames, id: \.self) { name in
                                HStack {
                                    Text(name).lineLimit(1)
                                    Spacer()
                                    Menu(model.participantAlias(for: name)) {
                                        Button("Keep as a separate name") { model.setParticipantAlias(name, to: nil) }
                                        Divider()
                                        ForEach(state.observedNames.filter { SpeakerIdentities.key(model.participantAlias(for: $0)) != SpeakerIdentities.key(name) }, id: \.self) { target in
                                            Button("Same participant as \(target)") { model.setParticipantAlias(name, to: target) }
                                        }
                                    }
                                    .fixedSize()
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 110)
                }
                .font(.callout)
            }
            HStack(spacing: 8) {
                if let error = model.speakerNamesError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                }
                Spacer(minLength: 0)
                if model.isApplyingSpeakerNames { ProgressView().controlSize(.small) }
                if state.complete || model.hasSpeakerChanges {
                    Button("Cancel") { model.discardSpeakerNameChanges() }
                        .keyboardShortcut(.cancelAction)
                        .disabled(model.isApplyingSpeakerNames)
                }
                Button("Apply Names") { model.applySpeakerNameDrafts() }
                    .disabled(model.isApplyingSpeakerNames || (!model.hasSpeakerChanges && !state.complete && state.rows.allSatisfy { model.speakerName(for: $0).isEmpty }))
                    .help("Writes a named copy of the transcript. The original transcript is kept unchanged.")
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(0.04), in: .rect(cornerRadius: 8))
        .disabled(model.isApplyingSpeakerNames)
    }

    private var availableNames: [String] {
        var names = state.names
        for raw in model.speakerNameDrafts.values {
            if let name = SpeakerAttribution.cleanName(raw), !names.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
                names.append(name)
            }
        }
        return names
    }

    private func binding(_ row: SpeakerNames.Row) -> Binding<String> {
        Binding(get: { model.speakerName(for: row) }, set: { model.setSpeakerName($0, for: row.speaker) })
    }

    /// The reason while the suggestion stands; nothing once the user changes it.
    private func caption(_ row: SpeakerNames.Row) -> String {
        let linked = state.rows.filter { $0.speaker != row.speaker && model.speakerGroup(for: $0) == model.speakerGroup(for: row) }
        if let other = linked.first { return "Linked to \(other.label)" }
        let current = SpeakerAttribution.cleanName(model.speakerName(for: row))
        guard current == row.name else { return "" }
        return row.reason ?? ""
    }
}

private struct TurnView: View {
    let turn: TranscriptTurn
    let name: String
    let color: Color
    let highlighted: Bool
    /// Being spoken: highlighted while the player is open.
    let isActive: Bool
    /// nil when the recording has no audio to play.
    let play: (() -> Void)?
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            timestamp
                .frame(width: 62, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(color)
                Text(turn.text)
                    .font(.system(size: 14))
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // The highlight takes in the gutter and is drawn outside the layout, so nothing moves.
        .padding(EdgeInsets(top: 6, leading: 22, bottom: 6, trailing: 10))
        .background(isActive ? Color.accentColor.opacity(0.1) : (highlighted ? color.opacity(0.1) : .clear), in: .rect(cornerRadius: 7))
        .padding(EdgeInsets(top: -6, leading: -22, bottom: -6, trailing: -10))
        .onHover { hovering = $0 }
    }

    /// With audio, the timestamp and a play symbol in the gutter before it
    /// form one button; the symbol shows on hover and on the spoken turn.
    @ViewBuilder private var timestamp: some View {
        let clock = Text(RecordingFormat.clock(Int(turn.start)))
            .font(.callout)
            .monospacedDigit()
        if let play {
            Button(action: play) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Image(systemName: hovering || !isActive ? "play.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 9))
                        .frame(width: 14)
                        .foregroundStyle(.tint)
                        .opacity(hovering || isActive ? 1 : 0)
                    clock.foregroundStyle(hovering || isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            // The gutter hangs into the margin, so timestamps stay aligned with the header.
            .padding(.leading, -18)
            .help("Play from \(RecordingFormat.clock(Int(turn.start)))")
        } else {
            clock.foregroundStyle(.tertiary)
        }
    }
}

/// Playback controls under the transcript while a recording plays or is paused.
private struct PlayerBar: View {
    let player: TranscriptPlayer
    let following: Bool
    let showCurrent: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 10) {
                Button(player.isPlaying ? "Pause" : "Play", systemImage: player.isPlaying ? "pause.fill" : "play.fill") {
                    player.toggle()
                }
                .labelStyle(.iconOnly)
                .frame(width: 16)
                .help(player.isPlaying ? "Pause (Space)" : "Play (Space)")
                if let error = player.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                } else {
                    Text(RecordingFormat.clock(Int(player.time)))
                        .foregroundStyle(.secondary)
                    Slider(value: Binding(get: { player.time }, set: { player.seek(to: $0) }), in: 0...max(player.duration, 1))
                        .controlSize(.mini)
                        .disabled(player.duration == 0)
                    Text(RecordingFormat.clock(Int(player.duration)))
                        .foregroundStyle(.secondary)
                }
                if !following {
                    Button("Show Current", systemImage: "text.line.first.and.arrowtriangle.forward", action: showCurrent)
                        .labelStyle(.iconOnly)
                        .help("Scroll to the turn being spoken and keep following it")
                }
                Button("Close Player", systemImage: "xmark") { player.stop() }
                    .labelStyle(.iconOnly)
                    .help("Stop playback")
            }
            .buttonStyle(.borderless)
            .font(.callout)
            .monospacedDigit()
            .controlSize(.small)
            .padding(.horizontal, 14)
            .frame(height: 30)
        }
        .background(.bar)
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
        for turn in turns {
            let identity = turn.navigationID
            if colors[identity] == nil { colors[identity] = palette[colors.count % palette.count] }
        }
        return colors
    }
}

private struct S3StatusTag: View {
    let entry: RecordingEntry
    var enabled = true
    private var label: (String, String, Color) {
        if entry.s3Blocked { return ("S3 sync blocked", "hand.raised.fill", .orange) }
        guard let record = entry.s3Upload else { return ("Not uploaded to S3", "icloud.slash", .secondary) }
        if record.phase != .uploaded, record.syncGeneration != entry.s3SyncPreference.generation {
            return ("S3 sync stopped", "pause.circle", .secondary)
        }
        switch record.phase {
        case .queued: return enabled || record.manualRequest == true ? ("Waiting for S3 upload", "clock", .secondary) : ("S3 upload paused", "pause.circle", .secondary)
        case .uploading: return ("Uploading to S3…", "icloud.and.arrow.up", .blue)
        case .failed: return ("S3 upload failed", "exclamationmark.icloud", .orange)
        case .uploaded: return entry.s3Current ? ("Uploaded to S3", "checkmark.icloud.fill", .green)
            : ("Changes not uploaded", "icloud.and.arrow.up", .orange)
        }
    }
    var body: some View {
        Label(label.0, systemImage: label.1)
            .font(.caption.weight(.medium))
            .foregroundStyle(label.2)
            .accessibilityLabel(label.0)
    }
}

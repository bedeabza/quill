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
        Button(entry.hasTranscript ? "Regenerate…" : "Transcribe…") { regenerate(entry) }
            .disabled(!model.canRegenerate(entry))
        if model.selection == entry.directory, model.speakerNames?.rows.isEmpty == false {
            Button("Name Speakers…") { model.editingSpeakerNames = true }
                .disabled(model.showsSpeakerNames)
        }
        Divider()
        Button("Delete…") { confirmDelete(entry, model: model) }
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
                        RecordingRow(entry: entry, status: model.status(of: entry))
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
    let regenerate: (RecordingEntry) -> Void
    /// Scroll to the spoken turn when it moves out of view; off once the user
    /// scrolls, on again when they play a turn or choose Show Current.
    @State private var following = true
    @State private var visibleTurns: Set<Int> = []
    @FocusState private var transcriptFocused: Bool

    var body: some View {
        ScrollViewReader { proxy in
            scroll
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
        }
        .onChange(of: entry.directory) { visibleTurns = []; following = true }
    }

    private var scroll: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.bottom, 18)
                if let banner {
                    banner.padding(.bottom, 18)
                }
                if model.showsSpeakerNames, let state = model.speakerNames {
                    SpeakerNamesForm(model: model, state: state, colors: turnColors)
                        .id(state)
                        .padding(.bottom, 18)
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
        .onScrollPhaseChange { _, phase in if phase == .interacting { following = false } }
        // Space plays and pauses once a turn was played, without taking it from text fields.
        .focusable()
        .focusEffectDisabled()
        .focused($transcriptFocused)
        .onKeyPress(.space) {
            guard model.player.directory == entry.directory else { return .ignored }
            model.player.toggle()
            return .handled
        }
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
                    .textSelection(.enabled)
                    .help(entry.originalTitle.map { $0 == entry.title ? "" : "Original title: \($0)" } ?? "")
                titleButton
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
                        TurnView(turn: turn, color: colors[turn.speaker] ?? .primary, isActive: turn.id == active,
                                 play: playable ? { play(turn) } : nil)
                            .id(turn.id)
                            .onScrollVisibilityChange(threshold: 0.8) { visible in
                                if visible { visibleTurns.insert(turn.id) } else { visibleTurns.remove(turn.id) }
                            }
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

/// "Speaker 1 is [name]" for each voice of a Scribe transcript, pre-selected
/// with the most likely name. Apply writes the named copy; the original stays.
private struct SpeakerNamesForm: View {
    let model: RecordingsModel
    let state: SpeakerNames.State
    /// Transcript colours by displayed speaker, so each row matches its turns.
    let colors: [String: Color]
    @State private var choices: [String: String?]

    init(model: RecordingsModel, state: SpeakerNames.State, colors: [String: Color]) {
        self.model = model
        self.state = state
        self.colors = colors
        _choices = State(initialValue: Dictionary(uniqueKeysWithValues: state.rows.map { ($0.speaker, $0.name) }))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Speakers")
                    .font(.headline)
                Text(state.rows.contains { $0.reason != nil }
                     ? "Check the suggested names, then apply them to a named copy of the transcript."
                     : "Choose who each voice is to create a named copy of the transcript.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 6) {
                ForEach(state.rows, id: \.speaker) { row in
                    GridRow {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(colors[row.label] ?? row.name.flatMap { colors[$0] } ?? Color.secondary)
                                .frame(width: 7, height: 7)
                            Text("\(row.label) is")
                        }
                        Picker(row.label, selection: binding(row.speaker)) {
                            ForEach(state.names, id: \.self) { name in Text(name).tag(Optional(name)) }
                            Divider()
                            Text("Unknown").tag(String?.none)
                        }
                        .labelsHidden()
                        .fixedSize()
                        Text(caption(row))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            HStack(spacing: 8) {
                if let error = model.speakerNamesError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                }
                Spacer(minLength: 0)
                if model.isApplyingSpeakerNames { ProgressView().controlSize(.small) }
                if state.complete {
                    Button("Cancel") { model.editingSpeakerNames = false }
                        .keyboardShortcut(.cancelAction)
                }
                Button("Apply Names") { model.applySpeakerNames(choices) }
                    .disabled(model.isApplyingSpeakerNames || (!state.complete && choices.values.allSatisfy { $0 == nil }))
                    .help("Writes a named copy of the transcript. The original transcript is kept unchanged.")
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(0.04), in: .rect(cornerRadius: 8))
    }

    private func binding(_ speaker: String) -> Binding<String?> {
        Binding(get: { choices[speaker] ?? nil }, set: { choices[speaker] = $0 })
    }

    /// The reason while the suggestion stands; nothing once the user changes it.
    private func caption(_ row: SpeakerNames.Row) -> String {
        let current = choices[row.speaker] ?? nil
        guard current == row.name else { return "" }
        return row.reason ?? ""
    }
}

private struct TurnView: View {
    let turn: TranscriptTurn
    let color: Color
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
                Text(turn.speaker)
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
        .background(isActive ? Color.accentColor.opacity(0.1) : .clear, in: .rect(cornerRadius: 7))
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
        for turn in turns where colors[turn.speaker] == nil {
            colors[turn.speaker] = palette[colors.count % palette.count]
        }
        return colors
    }
}

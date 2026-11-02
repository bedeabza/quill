import AppKit

@MainActor
private final class RecordingRowView: NSTableRowView {
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
    override func drawSelection(in dirtyRect: NSRect) {
        NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 2), xRadius: 6, yRadius: 6).fill()
    }
}

@MainActor
final class RecordingsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSWindowDelegate {
    private var root: URL
    private let transcription: TranscriptionCoordinator
    private var entries: [RecordingEntry] = []
    private var visible: [RecordingEntry] = []
    private var activity: [URL: TranscriptionCoordinator.Activity] = [:]
    private var refreshTask: Task<Void, Never>?
    private var timer: Timer?
    private var previewTask: Task<Void, Never>?
    private var previewSignature: String?
    private var previewRequest = UUID()
    private var preferredSelection: URL?
    private var permissionsWindow: PermissionsWindowController?
    private let table = NSTableView()
    private let search = NSSearchField()
    private let rootLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "Select a recording")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let preview = NSTextView()
    private let variant = NSSegmentedControl(labels: ["Original", "With names"], trackingMode: .selectOne, target: nil, action: nil)
    private let engine = NSPopUpButton()
    private let fresh = NSButton(checkboxWithTitle: "Request a new ElevenLabs transcript", target: nil, action: nil)
    private let cloudNote = NSTextField(wrappingLabelWithString: "Saved responses are reused when available. A new ElevenLabs request uploads audio again and may be billed again.")
    private let regenerateButton = NSButton(title: "Regenerate", target: nil, action: nil)
    private let openButton = NSButton(title: "Open folder", target: nil, action: nil)

    init(root: URL, transcription: TranscriptionCoordinator) {
        self.root = RecordingsLibrary.canonicalDirectory(root)
        self.transcription = transcription
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Quill Recordings"
        window.minSize = NSSize(width: 860, height: 560)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildContent()
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show() {
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        refresh()
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
    }

    func windowWillClose(_ notification: Notification) { timer?.invalidate(); timer = nil }

    private func buildContent() {
        guard let content = window?.contentView else { return }
        let choose = NSButton(title: "Choose folder…", target: self, action: #selector(chooseFolder))
        let refresh = NSButton(title: "Refresh", target: self, action: #selector(refreshClicked))
        let permissions = NSButton(title: "Permissions…", target: self, action: #selector(checkPermissions))
        choose.setContentHuggingPriority(.required, for: .horizontal)
        refresh.setContentHuggingPriority(.required, for: .horizontal)
        rootLabel.lineBreakMode = .byTruncatingMiddle
        rootLabel.textColor = .secondaryLabelColor
        let header = NSStackView(views: [rootLabel, choose, permissions, refresh])
        header.distribution = .fill
        header.spacing = 8
        rootLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        search.placeholderString = "Search recordings or participants"
        search.delegate = self
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("recording"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 62
        table.style = .sourceList
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openFolder)
        table.setAccessibilityLabel("Recordings")
        let listScroll = NSScrollView()
        listScroll.documentView = table
        listScroll.hasVerticalScroller = true
        let sidebar = NSStackView(views: [search, listScroll])
        sidebar.orientation = .vertical
        sidebar.distribution = .fill
        sidebar.alignment = .leading
        sidebar.spacing = 10
        sidebar.widthAnchor.constraint(equalToConstant: 270).isActive = true
        for view in [search, listScroll] { view.widthAnchor.constraint(equalTo: sidebar.widthAnchor).isActive = true }

        titleLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        detailLabel.font = .systemFont(ofSize: 12)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.maximumNumberOfLines = 2
        variant.selectedSegment = 0
        variant.target = self
        variant.action = #selector(variantChanged)
        openButton.target = self
        openButton.action = #selector(openFolder)
        let tools = NSStackView(views: [variant, NSView(), openButton])
        tools.distribution = .fill
        tools.spacing = 8
        for kind in TranscriptionEngineKind.allCases { engine.addItem(withTitle: kind.title) }
        engine.selectItem(at: TranscriptionEngineKind.allCases.firstIndex(where: { $0.rawValue == Config.transcriptionEngine() }) ?? 0)
        engine.target = self
        engine.action = #selector(engineChanged)
        engine.setAccessibilityLabel("Transcription engine for regeneration")
        engine.toolTip = "Applies to this regeneration without changing the default engine."
        engine.widthAnchor.constraint(equalToConstant: 220).isActive = true
        regenerateButton.bezelStyle = .rounded
        regenerateButton.target = self
        regenerateButton.action = #selector(regenerate)
        let actions = NSStackView(views: [engine, NSView(), regenerateButton])
        actions.distribution = .fill
        actions.spacing = 10
        cloudNote.font = .systemFont(ofSize: 12)
        cloudNote.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.maximumNumberOfLines = 3
        let backupNote = NSTextField(wrappingLabelWithString: "Previous transcripts are backed up before regeneration.")
        backupNote.font = .systemFont(ofSize: 12)
        backupNote.textColor = .secondaryLabelColor
        preview.isEditable = false
        preview.isSelectable = true
        preview.font = .systemFont(ofSize: 14)
        preview.textContainerInset = NSSize(width: 16, height: 16)
        preview.isHorizontallyResizable = false
        preview.isVerticallyResizable = true
        preview.autoresizingMask = [.width]
        preview.textContainer?.widthTracksTextView = true
        preview.setAccessibilityLabel("Transcript preview")
        let transcriptScroll = NSScrollView()
        transcriptScroll.hasVerticalScroller = true
        transcriptScroll.borderType = .bezelBorder
        transcriptScroll.documentView = preview
        transcriptScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        let detail = NSStackView(views: [titleLabel, detailLabel, tools, actions, fresh, cloudNote, backupNote, statusLabel, transcriptScroll])
        detail.orientation = .vertical
        detail.distribution = .fill
        detail.detachesHiddenViews = true
        detail.alignment = .leading
        detail.spacing = 10
        for view in [titleLabel, detailLabel, tools, actions, cloudNote, backupNote, statusLabel, transcriptScroll] {
            view.widthAnchor.constraint(equalTo: detail.widthAnchor).isActive = true
        }
        let body = NSStackView(views: [sidebar, detail])
        body.distribution = .fill
        body.alignment = .top
        body.spacing = 20
        sidebar.heightAnchor.constraint(equalTo: body.heightAnchor).isActive = true
        detail.heightAnchor.constraint(equalTo: body.heightAnchor).isActive = true
        let layout = NSStackView(views: [header, body])
        layout.orientation = .vertical
        layout.distribution = .fill
        layout.alignment = .leading
        layout.spacing = 16
        content.addSubview(layout)
        layout.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            layout.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            layout.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            layout.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            layout.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            header.widthAnchor.constraint(equalTo: layout.widthAnchor), body.widthAnchor.constraint(equalTo: layout.widthAnchor)
        ])
        updateSelection()
    }

    func refresh() {
        guard refreshTask == nil else { return }
        let requestedRoot = root
        let selected = selectedEntry?.directory
        refreshTask = Task { [weak self, transcription] in
            let states = await transcription.activity()
            let result = await Task.detached(priority: .utility) { Result { try RecordingsLibrary.entries(in: requestedRoot) } }.value
            guard let self else { return }
            self.refreshTask = nil
            guard self.root == requestedRoot else { self.refresh(); return }
            self.activity = states
            self.rootLabel.stringValue = requestedRoot.path
            switch result {
            case .success(let rows):
                self.entries = rows
                // Respect a selection made while the directory scan was running.
                self.filterEntries(selecting: self.preferredSelection ?? self.selectedEntry?.directory ?? selected)
                self.preferredSelection = nil
            case .failure(let error):
                self.entries = []
                self.filterEntries(selecting: nil)
                self.statusLabel.stringValue = "Could not read this folder: \(error)"
            }
        }
    }

    private var selectedEntry: RecordingEntry? {
        visible.indices.contains(table.selectedRow) ? visible[table.selectedRow] : nil
    }
    private var selectedEngine: TranscriptionEngineKind { TranscriptionEngineKind.allCases[max(0, engine.indexOfSelectedItem)] }

    private func filterEntries(selecting directory: URL?) {
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        visible = entries.filter { query.isEmpty || ([$0.title, $0.directory.lastPathComponent] + $0.participants).joined(separator: " ").localizedCaseInsensitiveContains(query) }
        table.reloadData()
        if let index = visible.firstIndex(where: { $0.directory == directory }) ?? (visible.isEmpty ? nil : 0) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        } else { table.deselectAll(nil) }
        updateSelection()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { visible.count }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { RecordingRowView() }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("RecordingCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? NSTableCellView()
        if cell.textField == nil {
            cell.identifier = identifier
            let title = NSTextField(labelWithString: "")
            title.lineBreakMode = .byTruncatingTail
            let subtitle = NSTextField(labelWithString: "")
            subtitle.tag = 2
            subtitle.font = .systemFont(ofSize: 11)
            subtitle.textColor = .secondaryLabelColor
            subtitle.lineBreakMode = .byTruncatingTail
            cell.addSubview(title); cell.addSubview(subtitle)
            cell.textField = title
            title.translatesAutoresizingMaskIntoConstraints = false
            subtitle.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                title.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8), title.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                title.topAnchor.constraint(equalTo: cell.topAnchor, constant: 10),
                subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor), subtitle.trailingAnchor.constraint(equalTo: title.trailingAnchor),
                subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4)
            ])
        }
        let entry = visible[row]
        cell.textField?.stringValue = entry.title
        let date = DateFormatter.localizedString(from: entry.startedAt, dateStyle: .short, timeStyle: .short)
        (cell.viewWithTag(2) as? NSTextField)?.stringValue = date + " · " + shortStatus(entry)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateSelection() }
    func controlTextDidChange(_ obj: Notification) { filterEntries(selecting: selectedEntry?.directory) }

    private func shortStatus(_ entry: RecordingEntry) -> String {
        switch activity[entry.directory] {
        case .queued: return "Queued"
        case .processing: return "Transcribing"
        case .failed: return "Failed"
        case nil: return entry.hasTranscript ? "Ready" : (entry.canRegenerate ? "Not transcribed" : "Unfinished")
        }
    }

    private func updateSelection() {
        let entry = selectedEntry
        titleLabel.stringValue = entry?.title ?? (entries.isEmpty ? "No recordings yet" : "No matching recordings")
        detailLabel.stringValue = entry.map {
            let date = DateFormatter.localizedString(from: $0.startedAt, dateStyle: .medium, timeStyle: .short)
            let duration = $0.duration.map { " · \($0 / 60)m \($0 % 60)s" } ?? ""
            return date + duration + "\n" + ($0.participants.isEmpty ? "Participants not recorded" : $0.participants.joined(separator: ", "))
        } ?? "Choose a recordings folder or start a recording from the Quill menu."
        let busy: Bool
        switch entry.flatMap({ activity[$0.directory] }) {
        case .queued:
            let current = activity.first { $0.value == .processing }?.key.lastPathComponent
            statusLabel.stringValue = current.map { "Queued — waiting for \($0) to finish. Recordings are processed one at a time." }
                ?? "Queued — waiting for the transcription worker. Check Permissions… if this does not change."
            busy = true
        case .processing: statusLabel.stringValue = "Transcribing… You can browse other recordings while this runs."; busy = true
        case .failed(let reason): statusLabel.stringValue = "Regeneration failed: \(reason)"; busy = false
        case nil: statusLabel.stringValue = entry?.canRegenerate == false ? "This recording is unfinished or its audio is unavailable." : ""; busy = false
        }
        regenerateButton.isEnabled = entry?.canRegenerate == true && !busy
        openButton.isEnabled = entry != nil
        variant.isEnabled = entry != nil
        variant.setEnabled(entry?.hasNamedTranscript == true, forSegment: 1)
        if entry?.hasNamedTranscript != true { variant.selectedSegment = 0 }
        fresh.isHidden = selectedEngine != .elevenLabs
        cloudNote.isHidden = selectedEngine != .elevenLabs
        updatePreview(entry, named: variant.selectedSegment == 1)
    }

    private func updatePreview(_ entry: RecordingEntry?, named: Bool) {
        guard let entry else {
            previewRequest = UUID(); previewSignature = nil; previewTask?.cancel(); preview.string = ""
            return
        }
        let base = named ? "transcript-named" : "transcript"
        let stamps = ["json", "md"].map { ext in
            let values = try? entry.directory.appendingPathComponent(base + "." + ext).resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            return "\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0):\(values?.fileSize ?? 0)"
        }.joined(separator: ":")
        let signature = entry.directory.path + "/" + base + "/" + stamps
        guard signature != previewSignature else { return }
        previewSignature = signature
        previewTask?.cancel()
        let request = UUID()
        previewRequest = request
        previewTask = Task { [weak self] in
            let text = await Task.detached(priority: .utility) {
                (try? RecordingsLibrary.preview(in: entry.directory, named: named)) ?? "Could not read the transcript. Open its folder to inspect it."
            }.value
            guard let self, self.previewRequest == request else { return }
            if self.preview.string != text {
                self.preview.string = text
                self.preview.scrollRangeToVisible(NSRange(location: 0, length: 0))
            }
        }
    }

    @objc private func refreshClicked() { refresh() }
    @objc private func variantChanged() { updateSelection() }
    @objc private func engineChanged() { updateSelection() }
    @objc private func openFolder() { if let entry = selectedEntry { NSWorkspace.shared.open(entry.directory) } }

    @objc private func checkPermissions() {
        permissionsWindow?.close()
        permissionsWindow = PermissionsWindowController(root: root, recording: selectedEntry?.directory, engine: selectedEngine)
        permissionsWindow?.show()
    }
    @objc private func chooseFolder() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = root
        panel.prompt = "Browse recordings"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            let selected = RecordingsLibrary.canonicalDirectory(url)
            if FileManager.default.fileExists(atPath: selected.appendingPathComponent("meta.json").path) {
                self.root = selected.deletingLastPathComponent()
                self.preferredSelection = selected
            } else {
                self.root = selected
                self.preferredSelection = nil
            }
            self.search.stringValue = ""
            self.refresh()
        }
    }
    @objc private func regenerate() {
        guard let entry = selectedEntry, regenerateButton.isEnabled else { return }
        let kind = selectedEngine
        let freshCloud = fresh.state == .on
        regenerateButton.isEnabled = false
        statusLabel.stringValue = "Adding recording to the queue…"
        Task { [weak self, transcription] in
            do { try await transcription.regenerate(entry.directory, engine: kind, freshCloud: freshCloud); self?.refresh() }
            catch { self?.statusLabel.stringValue = String(describing: error); self?.regenerateButton.isEnabled = true }
        }
    }
}

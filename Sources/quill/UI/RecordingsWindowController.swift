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
private final class RecordingDateNode: NSObject {
    let scope: RecordingCalendar.Scope
    let label: String
    let count: Int
    let children: [RecordingDateNode]
    init(scope: RecordingCalendar.Scope, label: String, count: Int, children: [RecordingDateNode] = []) {
        self.scope = scope; self.label = label; self.count = count; self.children = children
    }
}

@MainActor
final class RecordingsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate, NSSearchFieldDelegate, NSWindowDelegate {
    private var root: URL
    private let transcription: TranscriptionCoordinator
    private let titles: RecordingTitleCoordinator
    private var titleBusy: Set<URL> = []
    private let dates = NSOutlineView()
    private var dateNodes: [RecordingDateNode] = []
    private var dateScope: RecordingCalendar.Scope?
    private var updatingDates = false
    private var calendarSignature: String?
    private let dayLabel = NSTextField(labelWithString: "Recordings")
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
    private let cloudNote = NSTextField(wrappingLabelWithString: "One aligned recording with echo reduction is sent to ElevenLabs. Matching combined responses are reused. Older separate-track results need a new upload, which may be billed.")
    private let regenerateButton = NSButton(title: "Regenerate", target: nil, action: nil)
    private let openButton = NSButton(title: "Open folder", target: nil, action: nil)
    private let titleButton = NSButton(title: "Generate title", target: nil, action: nil)

    init(root: URL, transcription: TranscriptionCoordinator, titles: RecordingTitleCoordinator = .shared) {
        self.root = RecordingsLibrary.canonicalDirectory(root)
        self.transcription = transcription
        self.titles = titles
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
        permissions.setContentHuggingPriority(.required, for: .horizontal)
        rootLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        rootLabel.lineBreakMode = .byTruncatingMiddle
        rootLabel.textColor = .secondaryLabelColor
        let header = NSStackView(views: [rootLabel, choose, permissions, refresh])
        header.distribution = .fill
        header.spacing = 8
        rootLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        search.placeholderString = "Search recordings or participants"
        search.delegate = self
        let dateColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("dates"))
        dates.addTableColumn(dateColumn); dates.outlineTableColumn = dateColumn
        dates.headerView = nil; dates.rowHeight = 27; dates.indentationPerLevel = 12; dates.style = .sourceList
        dates.dataSource = self; dates.delegate = self
        dates.setAccessibilityLabel("Recording months and days")
        let dateScroll = NSScrollView(); dateScroll.documentView = dates; dateScroll.hasVerticalScroller = true
        dateScroll.heightAnchor.constraint(equalToConstant: 190).isActive = true
        dayLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        dayLabel.lineBreakMode = .byTruncatingTail
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("recording"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 64
        table.style = .sourceList
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openFolder)
        table.setAccessibilityLabel("Recordings")
        let listScroll = NSScrollView()
        listScroll.documentView = table
        listScroll.hasVerticalScroller = true
        let sidebar = NSStackView(views: [search, dateScroll, dayLabel, listScroll])
        sidebar.orientation = .vertical
        sidebar.distribution = .fill
        sidebar.alignment = .leading
        sidebar.spacing = 10
        sidebar.widthAnchor.constraint(equalToConstant: 270).isActive = true
        for view in [search, dateScroll, dayLabel, listScroll] { view.widthAnchor.constraint(equalTo: sidebar.widthAnchor).isActive = true }

        titleLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleButton.target = self; titleButton.action = #selector(generateTitle)
        titleButton.font = .systemFont(ofSize: 11)
        titleButton.setContentHuggingPriority(.required, for: .horizontal)
        let titleRow = NSStackView(views: [titleLabel, titleButton]); titleRow.distribution = .fill; titleRow.spacing = 8
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
        let detail = NSStackView(views: [titleRow, detailLabel, tools, actions, fresh, cloudNote, backupNote, statusLabel, transcriptScroll])
        detail.orientation = .vertical
        detail.distribution = .fill
        detail.detachesHiddenViews = true
        detail.alignment = .leading
        detail.spacing = 10
        for view in [titleRow, detailLabel, tools, actions, cloudNote, backupNote, statusLabel, transcriptScroll] {
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
        refreshTask = Task { [weak self, transcription, titles] in
            let states = await transcription.activity()
            let titleStates = await titles.busy()
            let result = await Task.detached(priority: .utility) { Result { try RecordingsLibrary.entries(in: requestedRoot) } }.value
            guard let self else { return }
            self.refreshTask = nil
            guard self.root == requestedRoot else { self.refresh(); return }
            self.activity = states
            self.titleBusy = titleStates
            self.rootLabel.stringValue = requestedRoot.path
            switch result {
            case .success(let rows):
                self.entries = rows
                self.rebuildDates(selecting: self.preferredSelection)
                // Respect a selection made while the directory scan was running.
                self.filterEntries(selecting: self.preferredSelection ?? self.selectedEntry?.directory ?? selected)
                self.preferredSelection = nil
            case .failure(let error):
                self.entries = []
                self.rebuildDates(selecting: nil)
                self.filterEntries(selecting: nil)
                self.statusLabel.stringValue = "Could not read this folder: \(error)"
            }
        }
    }

    private var selectedEntry: RecordingEntry? {
        visible.indices.contains(table.selectedRow) ? visible[table.selectedRow] : nil
    }
    private var selectedEngine: TranscriptionEngineKind { TranscriptionEngineKind.allCases[max(0, engine.indexOfSelectedItem)] }

    private func dateLabel(_ date: Date, format: String) -> String {
        let formatter = DateFormatter(); formatter.setLocalizedDateFormatFromTemplate(format)
        return formatter.string(from: date)
    }
    private func exactTiming(_ entry: RecordingEntry) -> String {
        let formatter = DateFormatter(); formatter.dateStyle = .medium; formatter.timeStyle = .medium
        return formatter.string(from: entry.startedAt) + " → " + (entry.endedAt.map { formatter.string(from: $0) } ?? "End unavailable")
    }
    private func rebuildDates(selecting directory: URL?) {
        let signature = Calendar.autoupdatingCurrent.timeZone.identifier + Locale.autoupdatingCurrent.identifier
            + entries.map { $0.directory.path + ":\($0.startedAt.timeIntervalSince1970)" }.joined(separator: "|")
        guard directory != nil || calendarSignature != signature else { return }
        calendarSignature = signature
        let expanded = Set(dateNodes.filter { dates.isItemExpanded($0) }.map(\.scope))
        let months = RecordingCalendar.months(entries)
        if let directory, let entry = entries.first(where: { $0.directory == directory }) {
            dateScope = .day(Calendar.autoupdatingCurrent.startOfDay(for: entry.startedAt))
        }
        dateNodes = [RecordingDateNode(scope: .all, label: "All recordings", count: entries.count)] + months.map { month in
            RecordingDateNode(scope: .month(month.date), label: dateLabel(month.date, format: "MMMM yyyy"), count: month.count,
                children: month.days.map { RecordingDateNode(scope: .day($0.date), label: dateLabel($0.date, format: "EEEE d"), count: $0.count) })
        }
        let all = dateNodes + dateNodes.flatMap(\.children)
        if dateScope == nil || !all.contains(where: { $0.scope == dateScope }) {
            dateScope = months.first?.days.first.map { .day($0.date) } ?? .all
        }
        updatingDates = true
        defer { updatingDates = false }
        dates.reloadData()
        for node in dateNodes where !node.children.isEmpty {
            if expanded.contains(node.scope) || node.children.contains(where: { $0.scope == dateScope }) { dates.expandItem(node) }
        }
        if let selected = all.first(where: { $0.scope == dateScope }), dates.row(forItem: selected) >= 0 {
            dates.selectRowIndexes(IndexSet(integer: dates.row(forItem: selected)), byExtendingSelection: false)
        }
    }
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? RecordingDateNode)?.children.count ?? dateNodes.count
    }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        ((item as? RecordingDateNode)?.children ?? dateNodes)[index]
    }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { !(item as! RecordingDateNode).children.isEmpty }
    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? { RecordingRowView() }
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? RecordingDateNode else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("RecordingDate")
        let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? NSTableCellView()
        if cell.textField == nil {
            cell.identifier = identifier
            let label = NSTextField(labelWithString: ""); label.lineBreakMode = .byTruncatingTail
            cell.addSubview(label); cell.textField = label; label.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4), label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        }
        cell.textField?.stringValue = node.label + "  ·  \(node.count)"
        cell.textField?.font = .systemFont(ofSize: 12, weight: node.children.isEmpty ? .regular : .semibold)
        return cell
    }
    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !updatingDates, let node = dates.item(atRow: dates.selectedRow) as? RecordingDateNode else { return }
        dateScope = node.scope
        if !node.children.isEmpty { dates.expandItem(node) }
        filterEntries(selecting: nil)
    }

    private func filterEntries(selecting directory: URL?) {
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        visible = entries.filter {
            RecordingCalendar.includes($0, scope: dateScope ?? .all)
                && (query.isEmpty || ([$0.title, $0.originalTitle ?? "", $0.directory.lastPathComponent] + $0.participants).joined(separator: " ").localizedCaseInsensitiveContains(query))
        }
        let scopeName: String
        switch dateScope ?? .all {
        case .all: scopeName = "All recordings"; search.placeholderString = "Search all recordings"
        case .month(let date): scopeName = dateLabel(date, format: "MMMM yyyy"); search.placeholderString = "Search this month"
        case .day(let date): scopeName = dateLabel(date, format: "EEE, d MMM"); search.placeholderString = "Search this day"
        }
        dayLabel.stringValue = scopeName + " · \(visible.count)"
        table.reloadData()
        if let index = visible.firstIndex(where: { $0.directory == directory }) ?? (visible.isEmpty ? nil : 0) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        } else { table.deselectAll(nil) }
        updateSelection()
        let candidates = visible.filter { entry in
            guard entry.hasTranscript else { return false }
            switch activity[entry.directory] { case .queued, .processing: return false; default: return true }
        }.map(\.directory)
        Task { [titles] in await titles.enqueue(candidates) }
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
            title.maximumNumberOfLines = 2; title.cell?.wraps = true
            title.font = .systemFont(ofSize: 13, weight: .medium)
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
                title.topAnchor.constraint(equalTo: cell.topAnchor, constant: 8),
                subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor), subtitle.trailingAnchor.constraint(equalTo: title.trailingAnchor),
                subtitle.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -8),
                title.bottomAnchor.constraint(lessThanOrEqualTo: subtitle.topAnchor, constant: -4)
            ])
        }
        let entry = visible[row]
        cell.textField?.stringValue = entry.title
        let prefix: String
        if case .day = dateScope ?? .all { prefix = "" } else { prefix = dateLabel(entry.startedAt, format: "d MMM") + " · " }
        (cell.viewWithTag(2) as? NSTextField)?.stringValue = prefix + RecordingCalendar.compactTiming(entry) + " · " + shortStatus(entry)
        cell.toolTip = entry.title + "\n" + exactTiming(entry)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard (notification.object as? NSTableView) === table else { return }; updateSelection()
    }
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
        titleLabel.toolTip = entry?.title
        let titleRunning = entry.map { titleBusy.contains($0.directory) } ?? false
        titleButton.title = titleRunning ? "Generating…" : entry?.titleSource == nil ? "Generate title" : "Refresh title"
        titleButton.isEnabled = entry?.hasTranscript == true && !titleRunning
        titleButton.toolTip = "Creates a title from the meeting content. AI title modes send transcript excerpts to your configured text service; originals are preserved."
        detailLabel.stringValue = entry.map {
            let date = DateFormatter.localizedString(from: $0.startedAt, dateStyle: .medium, timeStyle: .none)
            return date + " · " + RecordingCalendar.compactTiming($0) + "\n" + ($0.participants.isEmpty ? "Participants not recorded" : $0.participants.joined(separator: ", "))
        } ?? "Choose a recordings folder or start a recording from the Quill menu."
        detailLabel.toolTip = entry.map(exactTiming)
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
        let contentSignature = entry.directory.path + "/" + base + "/" + stamps + "/"
        let preservePosition = previewSignature?.hasPrefix(contentSignature) == true
        let signature = contentSignature + entry.title
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
                let origin = self.preview.enclosingScrollView?.contentView.bounds.origin
                self.preview.string = text
                if preservePosition, let origin, let scroll = self.preview.enclosingScrollView {
                    scroll.contentView.scroll(to: origin); scroll.reflectScrolledClipView(scroll.contentView)
                } else { self.preview.scrollRangeToVisible(NSRange(location: 0, length: 0)) }
            }
        }
    }

    @objc private func refreshClicked() { refresh() }
    @objc private func generateTitle() {
        guard let entry = selectedEntry, titleButton.isEnabled else { return }
        titleButton.isEnabled = false; titleButton.title = "Generating…"
        Task { [weak self, titles] in
            await titles.enqueue([entry.directory], force: true)
            self?.refresh()
        }
    }
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
            self.dateScope = nil
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

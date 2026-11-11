import AppKit
import Observation

struct DaySection: Identifiable {
    var id: Date { day }
    /// Start of the day in the calendar the sections were built with.
    let day: Date
    let title: String
    let entries: [RecordingEntry]
}

enum RecordingStatus: Equatable {
    case ready, transcribing, queued, failed(String), notTranscribed, unfinished
}

/// Everything the Recordings section shows and does. Views bind to it; it owns
/// the folder scan, transcription and title queues, and the transcript preview.
@Observable @MainActor
final class RecordingsModel {
    /// The folder being browsed.
    private(set) var root: URL
    /// The folder passed at creation; `useDefaultRoot()` returns to it.
    let defaultRoot: URL
    var isDefaultRoot: Bool { root == defaultRoot }

    /// Every recording in `root`, newest first.
    private(set) var entries: [RecordingEntry] = []
    /// `entries` matching `query`, grouped by day, newest first.
    private(set) var sections: [DaySection] = []
    private(set) var activity: [URL: TranscriptionCoordinator.Activity] = [:]
    /// Recordings whose title is being generated.
    private(set) var titleBusy: Set<URL> = []
    /// Why `root` could not be read; nil when it could.
    private(set) var loadError: String?
    /// False until the first scan of `root` finishes, so an empty list is not
    /// mistaken for an empty folder.
    private(set) var hasLoaded = false

    /// Matches title, original title, folder name and participants.
    var query = "" { didSet { if query != oldValue { rebuild() } } }
    /// Directory of the selected recording. Kept across refreshes while it is
    /// visible; otherwise the first visible recording is selected.
    var selection: URL? {
        didSet {
            guard selection != oldValue else { return }
            regenerateError = nil
            editingSpeakerNames = false
            speakerNamesError = nil
            reloadTranscript()
        }
    }
    var selectedEntry: RecordingEntry? {
        selection.flatMap { url in sections.lazy.flatMap(\.entries).first { $0.directory == url } }
    }

    /// Preview of the selected transcript, the verified named copy when the
    /// recording has one; nil while nothing is selected or loading.
    private(set) var transcript: TranscriptPreview?
    /// Why part of the selected recording has no microphone audio; nil when it all does.
    private(set) var microphoneNotice: String?
    /// Voices of the selected Scribe transcript with their pre-selected names;
    /// nil when the recording has none to name.
    private(set) var speakerNames: SpeakerNames.State?
    /// Shows the speaker pickers although the named copy names everyone.
    var editingSpeakerNames = false
    private(set) var speakerNamesError: String?
    private(set) var isApplyingSpeakerNames = false
    var showsSpeakerNames: Bool {
        guard let state = speakerNames, !state.rows.isEmpty else { return false }
        return !state.complete || editingSpeakerNames
    }

    /// Engine for the next `regenerate()`; does not change the default engine.
    var regenerateEngine = TranscriptionEngineKind(rawValue: Config.transcriptionEngine()) ?? .parakeet
    /// Request a new ElevenLabs transcript instead of reusing a cached response.
    var freshCloud = false
    /// ElevenLabs uploads audio: show `freshCloud` and the upload note.
    var showsCloudOptions: Bool { regenerateEngine == .elevenLabs }
    private(set) var isEnqueuing = false
    private(set) var regenerateError: String?

    var selectedStatus: RecordingStatus? { selectedEntry.map { status(of: $0) } }
    /// Detail line for the selected recording: queue progress, failures, or nil.
    var selectedMessage: String? {
        guard let entry = selectedEntry else { return nil }
        if isEnqueuing { return "Adding recording to the queue…" }
        return regenerateError ?? Self.message(entry, activity: activity[entry.directory], allActivity: activity)
    }
    var canRegenerate: Bool { selectedEntry.map(canRegenerate) ?? false }
    func canRegenerate(_ entry: RecordingEntry) -> Bool {
        guard entry.canRegenerate, !isEnqueuing else { return false }
        switch activity[entry.directory] { case .queued, .processing: return false; default: return true }
    }

    @ObservationIgnored private let transcription: TranscriptionCoordinator
    @ObservationIgnored private let titles: RecordingTitleCoordinator
    @ObservationIgnored private let recordingDirectory: @MainActor () -> URL?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var preferredSelection: URL?
    /// Bumped by `delete`, so a scan that started before it is not shown.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var appeared: Set<URL> = []
    @ObservationIgnored private var transcriptSignature: String?
    @ObservationIgnored private var transcriptRequest = UUID()

    /// `recordingDirectory` is the folder of the recording in progress, if any.
    init(root: URL, transcription: TranscriptionCoordinator, titles: RecordingTitleCoordinator = .shared,
         recordingDirectory: @escaping @MainActor () -> URL? = { nil }) {
        let root = RecordingsLibrary.canonicalDirectory(root)
        self.root = root
        self.defaultRoot = root
        self.transcription = transcription
        self.titles = titles
        self.recordingDirectory = recordingDirectory
    }

    // MARK: Lifecycle

    /// Refresh now and every 2 s until `stop()`. Call while the section is visible.
    func start() {
        refresh()
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func stop() { timer?.invalidate(); timer = nil }

    func refresh() {
        guard refreshTask == nil else { return }
        let requestedRoot = root, requestedGeneration = generation
        refreshTask = Task { [weak self, transcription, titles] in
            let states = await transcription.activity()
            let titleStates = await titles.busy()
            let result = await Task.detached(priority: .utility) { Result { try RecordingsLibrary.entries(in: requestedRoot) } }.value
            guard let self else { return }
            self.refreshTask = nil
            guard self.root == requestedRoot, self.generation == requestedGeneration else { self.refresh(); return }
            self.activity = states
            self.titleBusy = titleStates
            switch result {
            case .success(let rows): self.entries = rows; self.loadError = nil
            case .failure(let error): self.entries = []; self.loadError = error.localizedDescription
            }
            self.hasLoaded = true
            self.rebuild()
            self.preferredSelection = nil
            self.reloadTranscript()
            self.enqueueTitles()
        }
    }

    // MARK: Rows

    func status(of entry: RecordingEntry) -> RecordingStatus { Self.status(entry, activity[entry.directory]) }
    func isGeneratingTitle(_ entry: RecordingEntry) -> Bool { titleBusy.contains(entry.directory) }
    func canGenerateTitle(_ entry: RecordingEntry) -> Bool { entry.hasTranscript && !isGeneratingTitle(entry) }

    /// Call from a row's onAppear/onDisappear: titles are generated for
    /// recordings on screen, not for the whole library at once.
    func rowAppeared(_ entry: RecordingEntry) { appeared.insert(entry.directory); enqueueTitles() }
    func rowDisappeared(_ entry: RecordingEntry) { appeared.remove(entry.directory) }

    // MARK: Actions

    /// Generates or refreshes the title even when one exists.
    func generateTitle(_ entry: RecordingEntry) {
        guard canGenerateTitle(entry) else { return }
        titleBusy.insert(entry.directory)
        Task { [weak self, titles] in
            await titles.enqueue([entry.directory], force: true)
            self?.refresh()
        }
    }

    /// Starts each Regenerate sheet from the current default engine, so a default
    /// changed in Transcription settings is not overridden by an older choice.
    func prepareRegenerate() {
        regenerateEngine = TranscriptionEngineKind(rawValue: Config.transcriptionEngine()) ?? .parakeet
        freshCloud = false
    }

    /// Queues the selected recording with `regenerateEngine` and `freshCloud`.
    func regenerate() {
        guard let entry = selectedEntry, canRegenerate else { return }
        let kind = regenerateEngine, fresh = freshCloud
        isEnqueuing = true
        regenerateError = nil
        Task { [weak self, transcription] in
            do {
                try await transcription.regenerate(entry.directory, engine: kind, freshCloud: fresh)
                self?.activity[entry.directory] = .queued
            } catch { self?.regenerateError = String(describing: error) }
            self?.isEnqueuing = false
            self?.refresh()
        }
    }

    /// Writes the named copy of the selected recording: speaker ID to name, nil
    /// for Unknown. The original transcript is unchanged; names are `manual`.
    func applySpeakerNames(_ names: [String: String?]) {
        guard let entry = selectedEntry, !isApplyingSpeakerNames else { return }
        let chosen = names.compactMapValues { $0 }
        isApplyingSpeakerNames = true
        speakerNamesError = nil
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { Result { try SpeakerNames.apply(chosen, in: entry.directory) } }.value
            guard let self else { return }
            self.isApplyingSpeakerNames = false
            switch result {
            case .success: if self.selection == entry.directory { self.editingSpeakerNames = false }
            case .failure(let error): self.speakerNamesError = (error as? TranscriptionFailure)?.description ?? error.localizedDescription
            }
            self.refresh()
        }
    }

    func showInFinder(_ entry: RecordingEntry) { NSWorkspace.shared.open(entry.directory) }

    /// Why `entry` cannot be deleted right now, judged from the last refresh;
    /// nil when it can. `delete` checks again before moving anything.
    func deletionRefusal(_ entry: RecordingEntry) -> String? {
        if let recording = recordingDirectory(), RecordingsLibrary.canonicalDirectory(recording) == entry.directory {
            return "It is being recorded. Stop the recording first."
        }
        switch activity[entry.directory] {
        case .processing: return "It is being transcribed or processed. Delete it when that finishes."
        case .queued: return "It is queued for transcription. Delete it when that finishes."
        default: return nil
        }
    }

    /// Moves the recording's folder to the Trash, then selects the next row (or
    /// the previous one at the end). Returns why it was refused or failed.
    func delete(_ entry: RecordingEntry) async -> String? {
        if let refusal = deletionRefusal(entry) { return refusal }
        do { _ = try await transcription.moveToTrash(entry.directory) }
        catch { refresh(); return (error as? TranscriptionFailure)?.description ?? error.localizedDescription }
        if selection == entry.directory {
            preferredSelection = Self.selection(afterDeleting: entry.directory, in: sections.flatMap(\.entries).map(\.directory))
        }
        generation += 1
        entries.removeAll { $0.directory == entry.directory }
        rebuild()
        refresh()
        return nil
    }

    /// Browse `url` (from an NSOpenPanel). A recording folder opens its parent
    /// with that recording selected.
    func browse(_ url: URL) {
        let selected = RecordingsLibrary.canonicalDirectory(url)
        if FileManager.default.fileExists(atPath: selected.appendingPathComponent("meta.json").path) {
            open(selected.deletingLastPathComponent(), selecting: selected)
        } else {
            open(selected, selecting: nil)
        }
    }

    func useDefaultRoot() { open(defaultRoot, selecting: nil) }

    private func open(_ folder: URL, selecting directory: URL?) {
        root = folder
        hasLoaded = false
        preferredSelection = directory
        query = ""
        refresh()
    }

    // MARK: Internals

    private func rebuild() {
        sections = Self.sections(entries, query: query, now: Date(), calendar: .autoupdatingCurrent)
        let visible = sections.flatMap(\.entries)
        let wanted = preferredSelection ?? selection
        selection = visible.first { $0.directory == wanted }?.directory ?? visible.first?.directory
    }

    private func enqueueTitles() {
        let candidates = sections.flatMap(\.entries).filter { entry in
            guard appeared.contains(entry.directory), entry.hasTranscript else { return false }
            switch activity[entry.directory] { case .queued, .processing: return false; default: return true }
        }.map(\.directory)
        guard !candidates.isEmpty else { return }
        Task { [titles] in await titles.enqueue(candidates) }
    }

    /// Reloads the preview off the main actor when the selection or its
    /// transcript files change; results for an older request are dropped.
    private func reloadTranscript() {
        guard let entry = selectedEntry else {
            transcriptRequest = UUID(); transcriptSignature = nil; transcript = nil; speakerNames = nil; microphoneNotice = nil
            return
        }
        let named = entry.hasNamedTranscript
        let base = named ? "transcript-named" : "transcript"
        let files = [base + ".json", base + ".md", "transcript.json", "transcript-named.json", "speaker-mapping.json"]
        let stamps = files.map { file in
            let values = try? entry.directory.appendingPathComponent(file).resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            return "\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0):\(values?.fileSize ?? 0)"
        }.joined(separator: ":")
        let signature = entry.directory.path + "/" + base + "/" + stamps
        guard signature != transcriptSignature else { return }
        if transcriptSignature?.hasPrefix(entry.directory.path + "/") != true { speakerNames = nil; microphoneNotice = nil }
        if transcriptSignature?.hasPrefix(entry.directory.path + "/" + base + "/") != true { transcript = nil }
        transcriptSignature = signature
        let request = UUID()
        transcriptRequest = request
        Task { [weak self] in
            let (preview, names, notice) = await Task.detached(priority: .utility) {
                ((try? RecordingsLibrary.transcript(in: entry.directory, named: named))
                    ?? .empty("Could not read the transcript. Open its folder to inspect it."),
                 SpeakerNames.state(in: entry.directory),
                 MicrophoneGaps.notice(MicrophoneGaps.read(in: entry.directory), duration: entry.duration))
            }.value
            guard let self, self.transcriptRequest == request else { return }
            if self.transcript != preview { self.transcript = preview }
            if self.speakerNames != names { self.speakerNames = names }
            if self.microphoneNotice != notice { self.microphoneNotice = notice }
        }
    }

    // MARK: Pure helpers

    static func sections(_ entries: [RecordingEntry], query: String, now: Date, calendar: Calendar) -> [DaySection] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matching = query.isEmpty ? entries : entries.filter {
            ([$0.title, $0.originalTitle ?? "", $0.directory.lastPathComponent] + $0.participants)
                .joined(separator: " ").localizedCaseInsensitiveContains(query)
        }
        let days = Dictionary(grouping: matching) { calendar.startOfDay(for: $0.startedAt) }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = calendar.locale ?? .autoupdatingCurrent
        return days.keys.sorted(by: >).map { day in
            // Days from another year carry the year so they cannot be mistaken for this year's.
            formatter.setLocalizedDateFormatFromTemplate(calendar.isDate(day, equalTo: now, toGranularity: .year) ? "EEEE d MMMM" : "EEEE d MMMM yyyy")
            let title = calendar.isDate(day, inSameDayAs: now) ? "Today"
                : calendar.isDateInYesterday(day, relativeTo: now) ? "Yesterday" : formatter.string(from: day)
            let sorted = days[day]!.sorted {
                $0.startedAt == $1.startedAt ? $0.directory.lastPathComponent > $1.directory.lastPathComponent : $0.startedAt > $1.startedAt
            }
            return DaySection(day: day, title: title, entries: sorted)
        }
    }

    /// The recording to select after `deleted` leaves `visible`: the next one,
    /// or the previous one when it was last.
    static func selection(afterDeleting deleted: URL, in visible: [URL]) -> URL? {
        guard let index = visible.firstIndex(of: deleted) else { return nil }
        return index + 1 < visible.count ? visible[index + 1] : index > 0 ? visible[index - 1] : nil
    }

    static func status(_ entry: RecordingEntry, _ activity: TranscriptionCoordinator.Activity?) -> RecordingStatus {
        switch activity {
        case .queued: return .queued
        case .processing: return .transcribing
        case .failed(let reason): return .failed(reason)
        case nil: return entry.hasTranscript ? .ready : (entry.canRegenerate ? .notTranscribed : .unfinished)
        }
    }

    static func message(_ entry: RecordingEntry, activity: TranscriptionCoordinator.Activity?,
                        allActivity: [URL: TranscriptionCoordinator.Activity]) -> String? {
        switch activity {
        case .queued:
            let current = allActivity.first { $0.value == .processing }?.key.lastPathComponent
            return current.map { "Queued — waiting for \($0) to finish. Recordings are processed one at a time." }
                ?? "Queued — waiting for the transcription worker. Check Permissions if this does not change."
        case .processing: return "Transcribing… You can browse other recordings while this runs."
        case .failed(let reason): return "Transcription failed: \(reason)"
        case nil: return entry.canRegenerate ? nil : "This recording is unfinished or its audio is unavailable."
        }
    }
}

private extension Calendar {
    func isDateInYesterday(_ date: Date, relativeTo now: Date) -> Bool {
        guard let yesterday = self.date(byAdding: .day, value: -1, to: startOfDay(for: now)) else { return false }
        return isDate(date, inSameDayAs: yesterday)
    }
}

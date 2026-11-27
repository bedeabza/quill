import Darwin
import Foundation

struct S3UploadRecord: Codable, Equatable, Sendable {
    enum Phase: String, Codable, Sendable { case queued, uploading, uploaded, failed }
    var phase: Phase = .queued
    var destination: S3Configuration
    var key: String?
    var payloadHash: String?
    var sourceSignature: String?
    var uploadedAt: Date?
    var message: String?
    var retryable = false
    var attempts = 0
    var previousKeys: [String] = []
    /// A deliberate one-off upload may run while automatic syncing is disabled.
    var manualRequest: Bool? = nil
    var syncGeneration: String? = nil
    static let filename = "s3-upload.json"
    static let payloadName = ".s3-upload.md"

    static func read(in directory: URL) -> Self? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(filename)) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
    func write(in directory: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: directory.appendingPathComponent(Self.filename), options: .atomic)
    }
    var location: String { key.map { "s3://\(destination.bucket)/\($0)" } ?? destination.destination }
    func current(in directory: URL) -> Bool { sourceSignature == S3Markdown.signature(in: directory) }
}

/// Durable outbox. Only explicit completions/manual uploads create jobs; startup never uploads historical meetings wholesale.
actor S3UploadCoordinator {
    static let shared = S3UploadCoordinator()
    typealias Put = @Sendable (S3Configuration, String, Data, String) async throws -> Void
    private let configuration: @Sendable () -> S3Configuration
    private let secret: @Sendable (String) throws -> String?
    private let put: Put
    private let title: @Sendable (URL) async -> Void
    private let automaticRetry: Bool
    private var queue: [URL] = []
    private var active: URL?
    private var rerun: Set<URL> = []
    private var worker: Task<Void, Never>?
    private var activeTask: Task<Void, Never>?
    private var retries: [URL: Task<Void, Never>] = [:]
    private var persistenceErrors: [URL: String] = [:]

    init(configuration: @escaping @Sendable () -> S3Configuration = { Config.s3() },
         secret: @escaping @Sendable (String) throws -> String? = { try S3SecretStore().read($0) },
         put: @escaping Put = { try await S3Client().put(config: $0, key: $1, body: $2, secret: $3) },
         title: @escaping @Sendable (URL) async -> Void = { _ = await RecordingTitles.generate(in: $0, mode: Config.recordingTitleMode()) },
         automaticRetry: Bool = true) {
        self.configuration = configuration; self.secret = secret; self.put = put; self.title = title
        self.automaticRetry = automaticRetry
    }

    func errors() -> [URL: String] { persistenceErrors }
    func busy() -> Set<URL> { Set(queue).union(active.map { [$0] } ?? []) }
    func isBusy(_ directory: URL) -> Bool { active == directory || queue.contains(directory) }
    func waitUntilIdle() async { await worker?.value }

    /// Completions and saved corrections respect the discussion's block and the
    /// global automatic setting. Unchanged successful content is deduplicated.
    func enqueue(_ directory: URL) {
        let directory = RecordingsLibrary.canonicalDirectory(directory)
        guard configuration().enabled, !S3SyncPreference.read(in: directory).blocked else { return }
        if active == directory { rerun.insert(directory); return }
        if queue.contains(directory) { return }
        do { try queueNewCopy(directory, manual: false) }
        catch { persistenceErrors[directory] = String(describing: error) }
    }

    /// Explicitly sends a fresh immutable copy, even if already uploaded or
    /// automatic syncing is off. The UI names the unblock when it applies.
    func syncNow(_ directory: URL) throws {
        let directory = RecordingsLibrary.canonicalDirectory(directory)
        do {
            guard active != directory else { throw TranscriptionFailure("An upload is still stopping or finishing. Try Sync Now again in a moment.") }
            try queueNewCopy(directory, manual: true)
        }
        catch { persistenceErrors[directory] = String(describing: error); throw error }
    }

    func setBlocked(_ blocked: Bool, in directory: URL) throws {
        let directory = RecordingsLibrary.canonicalDirectory(directory)
        do {
            let control = try S3SyncPreference.lock(in: directory)
            defer { flock(control, LOCK_UN); close(control) }
            // Save permission before cancelling: it also survives app shutdown.
            try S3SyncPreference(blocked: blocked, generation: UUID().uuidString).write(in: directory)
            queue.removeAll { $0 == directory }
            rerun.remove(directory)
            retries.removeValue(forKey: directory)?.cancel()
            if active == directory { activeTask?.cancel() }
            persistenceErrors.removeValue(forKey: directory)
        } catch {
            let message = "Could not save this discussion’s S3 sync preference. Check the recording folder’s permissions."
            persistenceErrors[directory] = message
            throw TranscriptionFailure(message)
        }
    }

    private func queueNewCopy(_ directory: URL, manual: Bool) throws {
        let control = try S3SyncPreference.lock(in: directory)
        defer { flock(control, LOCK_UN); close(control) }
        let config = configuration()
        let preference = S3SyncPreference.read(in: directory)
        if !manual, preference.blocked || !config.enabled { return }
        if manual {
            _ = try config.validated()
            guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("transcript.json").path) else {
                throw TranscriptionFailure("Finish transcribing this discussion before syncing it.")
            }
        }
        let lock = open(directory.appendingPathComponent(".s3-upload.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw TranscriptionFailure("Could not save the S3 upload job.") }
        defer { flock(lock, LOCK_UN); close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            throw TranscriptionFailure("Another Quill process is uploading this meeting. Wait for it to finish before sending a correction.")
        }
        let previous = S3UploadRecord.read(in: directory)
        if !manual, let previous, previous.phase == .uploaded, previous.destination.sameDestination(as: config), previous.current(in: directory) { return }
        let nextPreference = manual ? S3SyncPreference(blocked: false, generation: UUID().uuidString) : preference
        var record = S3UploadRecord(destination: config)
        record.manualRequest = manual
        record.syncGeneration = nextPreference.generation
        record.previousKeys = previous?.previousKeys ?? []
        if let previous, previous.phase == .uploaded, previous.key != nil { record.previousKeys.append(previous.location) }
        // Neither old nor new work has permission between these two writes.
        try record.write(in: directory)
        if manual { try nextPreference.write(in: directory) }
        retries.removeValue(forKey: directory)?.cancel()
        rerun.remove(directory)
        persistenceErrors.removeValue(forKey: directory)
        queue.removeAll { $0 == directory }
        if manual { queue.insert(directory, at: 0) } else { queue.append(directory) }
        startWorker()
    }

    private func permitted(_ record: S3UploadRecord, in directory: URL) -> Bool {
        let preference = S3SyncPreference.read(in: directory)
        return !preference.blocked && preference.generation == record.syncGeneration
            && (configuration().enabled || record.manualRequest == true)
    }

    func resumePending(root: URL) {
        guard let directories = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return }
        for directory in directories { resume(directory) }
    }
    private func resume(_ directory: URL) {
        let directory = RecordingsLibrary.canonicalDirectory(directory)
        guard active != directory, !queue.contains(directory),
              let record = S3UploadRecord.read(in: directory), record.phase != .uploaded,
              permitted(record, in: directory) else { return }
        queue.append(directory); startWorker()
    }
    private func startWorker() {
        guard worker == nil else { return }
        worker = Task { await drain() }
    }
    private func drain() async {
        while !queue.isEmpty {
            let directory = queue.removeFirst(); active = directory
            let task = Task { await self.upload(directory) }
            activeTask = task
            await task.value
            activeTask = nil
            active = nil
            if rerun.remove(directory) != nil { enqueue(directory) }
        }
        worker = nil
    }

    private func upload(_ directory: URL) async {
        guard var record = S3UploadRecord.read(in: directory), permitted(record, in: directory), !Task.isCancelled else { return }
        // Inter-process exclusion also covers CLI retries and two app instances.
        let lock = open(directory.appendingPathComponent(".s3-upload.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard lock >= 0 else { persistenceErrors[directory] = "Could not lock the S3 upload job."; return }
        defer { flock(lock, LOCK_UN); close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { scheduleRetry(directory, attempts: record.attempts); return }
        do {
            let current = try configuration().validated()
            // A pending job never silently changes owner/bucket after settings are edited.
            guard current.sameDestination(as: record.destination) else {
                throw S3UploadFailure(description: "S3 destination changed. Use Sync Now to send this meeting to the current folder.")
            }
            record.destination.accessKeyID = current.accessKeyID
            guard let credential = try secret(current.accessKeyID) else {
                throw S3UploadFailure(description: "S3 secret is missing. Save it in Transcription settings, then retry.")
            }
            if record.key == nil {
                await title(directory)
                guard permitted(record, in: directory), !Task.isCancelled else { return }
                let processing = open(directory.appendingPathComponent(".postprocess.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
                guard processing >= 0 else { throw S3UploadFailure(description: "Could not lock this transcript for export.", retryable: true) }
                let document: S3Markdown.Document
                do {
                    defer { flock(processing, LOCK_UN); close(processing) }
                    guard flock(processing, LOCK_EX | LOCK_NB) == 0 else {
                        throw S3UploadFailure(description: "The transcript is still being processed. Upload will retry.", retryable: true)
                    }
                    document = try S3Markdown.make(in: directory)
                }
                let payload = directory.appendingPathComponent(S3UploadRecord.payloadName)
                try document.data.write(to: payload, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: payload.path)
                record.key = current.prefix + document.stem + "-" + UUID().uuidString.lowercased() + ".md"
                record.payloadHash = document.hash; record.sourceSignature = document.sourceSignature
            }
            guard permitted(record, in: directory), !Task.isCancelled else { return }
            let body = try Data(contentsOf: directory.appendingPathComponent(S3UploadRecord.payloadName))
            guard S3Signing.hash(body) == record.payloadHash, let key = record.key else {
                throw S3UploadFailure(description: "The saved upload copy is damaged. Use Sync Now to recreate it.")
            }
            record.phase = .uploading; record.message = nil; record.attempts += 1
            try record.write(in: directory) // persist key and immutable body before sending
            // No suspension between the permission check and starting the request.
            guard permitted(record, in: directory), !Task.isCancelled else { return }
            try await put(record.destination, key, body, credential)
            record.phase = .uploaded; record.uploadedAt = Date(); record.retryable = false
            try record.write(in: directory)
            persistenceErrors.removeValue(forKey: directory)
        } catch {
            record.phase = .failed
            record.message = (error as? S3UploadFailure)?.description ?? "Could not prepare or save the S3 upload. Check the configuration and recording files, then retry."
            record.retryable = !Task.isCancelled && permitted(record, in: directory) && ((error as? S3UploadFailure)?.retryable ?? false)
            if Task.isCancelled || !permitted(record, in: directory) {
                record.message = record.attempts > 0
                    ? "Upload cancelled. A request already sent to S3 may have completed; existing files are kept."
                    : "Upload stopped by this discussion’s sync preference."
            }
            do { try record.write(in: directory) }
            catch { persistenceErrors[directory] = "S3 upload status could not be saved. The upload is not confirmed locally." }
            if record.retryable { scheduleRetry(directory, attempts: record.attempts) }
        }
    }
    private func scheduleRetry(_ directory: URL, attempts: Int) {
        guard automaticRetry, let record = S3UploadRecord.read(in: directory), permitted(record, in: directory), !Task.isCancelled else { return }
        retries.removeValue(forKey: directory)?.cancel()
        let delay = [30, 120, 600][min(attempts, 2)]
        retries[directory] = Task {
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            self.resume(directory)
        }
    }
}

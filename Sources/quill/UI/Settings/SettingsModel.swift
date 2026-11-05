import Foundation
import Observation

/// The settings formerly in the menu. Reads and writes go straight to
/// `Config` and the key store; meeting detection goes through `AppState`.
/// A refused or failed change keeps the old value and sets `message`.
@Observable @MainActor
final class SettingsModel {
    enum KeyState: Equatable { case saved, notSet, problem(String) }

    /// Inline error or notice for the last change; nil when there is nothing to say.
    var message: String?
    private(set) var keyState: KeyState = .notSet
    /// True while the key is being saved or removed.
    private(set) var isUpdatingKey = false

    /// Default engine for new transcriptions. ElevenLabs needs a saved key.
    var engine: TranscriptionEngineKind {
        get { storedEngine }
        set {
            guard newValue != storedEngine else { return }
            // Re-assigning the stored value notifies observers, so a refused choice
            // snaps the picker back instead of showing a value that was not saved.
            if newValue == .elevenLabs {
                keyState = Self.keyState(keyStore.checkAccess())
                guard keyState == .saved else { message = "Save an ElevenLabs API key first."; storedEngine = storedEngine; return }
            }
            guard Config.setTranscriptionEngine(newValue) else {
                message = "Could not save the transcription engine setting."; storedEngine = storedEngine; return
            }
            storedEngine = newValue
            message = nil
        }
    }

    /// Transcript cleanup (cloud).
    var cleanupMode: PostProcessingMode {
        get { storedCleanup }
        set {
            guard newValue != storedCleanup else { return }
            guard Config.setPostProcessingMode(newValue) else {
                message = "Could not save the transcript cleanup setting."; storedCleanup = storedCleanup; return
            }
            storedCleanup = newValue
            message = nil
        }
    }

    /// Meeting titles: `.off` is local titles.
    var titleMode: PostProcessingMode {
        get { storedTitleMode }
        set {
            guard newValue != storedTitleMode else { return }
            guard Config.setRecordingTitleMode(newValue) else {
                message = "Could not save the title setting."; storedTitleMode = storedTitleMode; return
            }
            storedTitleMode = newValue
            message = nil
        }
    }

    /// Remember speaker voices.
    var voiceMemory: Bool {
        get { storedVoiceMemory }
        set {
            guard newValue != storedVoiceMemory else { return }
            do { try Config.setVoiceMemoryEnabled(newValue) }
            catch { message = "Could not save the speaker memory setting: \(error)"; storedVoiceMemory = storedVoiceMemory; return }
            storedVoiceMemory = newValue
            message = nil
        }
    }

    /// Automatic meeting recording; follows `AppState.detectionEnabled`.
    var automaticMeetingRecording: Bool {
        get { appState.detectionEnabled }
        set { if newValue != appState.detectionEnabled { appState.toggleDetection() } }
    }

    private var storedEngine: TranscriptionEngineKind = .parakeet
    private var storedCleanup: PostProcessingMode = .off
    private var storedTitleMode: PostProcessingMode = .off
    private var storedVoiceMemory = true
    @ObservationIgnored private let appState: AppState
    @ObservationIgnored private let keyStore: ElevenLabsKeyStore

    init(appState: AppState, keyStore: ElevenLabsKeyStore = .shared) {
        self.appState = appState
        self.keyStore = keyStore
        reload()
    }

    /// Re-reads every setting and the key state, e.g. when the section appears.
    func reload() {
        message = nil
        storedEngine = TranscriptionEngineKind(rawValue: Config.transcriptionEngine()) ?? .parakeet
        storedCleanup = Config.postProcessing().mode
        storedTitleMode = Config.recordingTitleMode()
        storedVoiceMemory = Config.voiceMemoryEnabled()
        keyState = Self.keyState(keyStore.checkAccess())
    }

    /// Saves the key; the value is not kept. Returns false and sets `message` on failure.
    @discardableResult func saveKey(_ value: String) async -> Bool {
        guard !isUpdatingKey else { return false }
        isUpdatingKey = true
        defer { isUpdatingKey = false }
        do {
            try await Task.detached { [keyStore] in try keyStore.save(value) }.value
            message = nil
        } catch {
            message = String(describing: error)
        }
        keyState = Self.keyState(keyStore.checkAccess())
        return keyState == .saved && message == nil
    }

    func removeKey() async {
        guard !isUpdatingKey else { return }
        isUpdatingKey = true
        defer { isUpdatingKey = false }
        do {
            try await Task.detached { [keyStore] in try keyStore.remove() }.value
            message = storedEngine == .elevenLabs
                ? "ElevenLabs API key removed. Select Parakeet or save another key to resume transcription." : nil
        } catch {
            message = String(describing: error)
        }
        keyState = Self.keyState(keyStore.checkAccess())
    }

    private static func keyState(_ access: ElevenLabsKeyStore.Access) -> KeyState {
        switch access {
        case .available: return .saved
        case .missing: return .notSet
        case .failed(let problem): return .problem(problem)
        }
    }
}

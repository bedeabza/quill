import AppKit
import AVFoundation
import Foundation

/// Checks run inside the installed app so macOS evaluates Quill's identity.
/// No recording, network request, or authorization prompt is started by a refresh.
enum PermissionsReport {
    enum Item: String, CaseIterable, Sendable {
        case microphone = "Microphone"
        case accessibility = "Meeting detection & participant names"
        case screen = "Zoom speaker detection"
        case systemAudio = "System audio"
        case notifications = "Notifications"
        case folder = "Recordings folder"
        case recording = "Selected recording"
        case transcription = "Transcription"
    }

    static func folder(_ directory: URL) -> Check {
        let fm = FileManager.default
        let probe = directory.appendingPathComponent(".quill-access-check-" + UUID().uuidString, isDirectory: true)
        do {
            _ = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            // Exercise the operations used by atomic transcript writes and backups.
            try fm.createDirectory(at: probe, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? fm.removeItem(at: probe) }
            let file = probe.appendingPathComponent("probe")
            let moved = probe.appendingPathComponent("renamed")
            let data = Data("Quill permission check".utf8)
            try data.write(to: file, options: .atomic)
            try fm.moveItem(at: file, to: moved)
            guard try Data(contentsOf: moved) == data else { throw CocoaError(.fileReadCorruptFile) }
            try fm.removeItem(at: moved)
            try fm.removeItem(at: probe)
            return Check(name: "folder", status: .ok, remediation: "Read, write, rename and delete work in \(directory.path)")
        } catch {
            return Check(name: "folder", status: .fail("Cannot read or write here: \(error.localizedDescription)"),
                         remediation: "Check folder permissions and Privacy & Security → Files and Folders. Choose another folder if needed.")
        }
    }

    static func recording(_ directory: URL) -> Check {
        do { try RecordingRegeneration.validate(directory) }
        catch { return Check(name: "recording", status: .fail(String(describing: error)), remediation: "The recording must be finished and its original audio files readable.") }
        return folder(directory)
    }

    static func transcription(engine: TranscriptionEngineKind, access: ElevenLabsKeychain.Access) -> Check {
        guard engine == .elevenLabs else { return DoctorReport.checkLocalModel() }
        let note = "Account quota and speech-to-text permission are confirmed only when ElevenLabs accepts a transcription request."
        switch access {
        case .available:
            return Check(name: "ElevenLabs key", status: .ok, remediation: "Quill can read the saved key. " + note)
        case .missing:
            return Check(name: "ElevenLabs key", status: .fail("No saved API key"), remediation: "Save a key using Quill → ElevenLabs API key…")
        case .needsAuthorization:
            return Check(name: "ElevenLabs key", status: .fail("Keychain approval or unlock required"), remediation: "Click Authorize key and approve the macOS prompt. " + note)
        case .failed(let message):
            return Check(name: "ElevenLabs key", status: .fail(message), remediation: "Unlock your login keychain or update the saved key from the Quill menu.")
        }
    }
}

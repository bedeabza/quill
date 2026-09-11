import ArgumentParser
import Darwin
import Foundation

extension TranscriptionEngineKind: ExpressibleByArgument {}

struct Transcription: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Select a transcription engine and manage the ElevenLabs key.",
        subcommands: [TranscriptionStatus.self, TranscriptionConfigure.self, TranscriptionKey.self])
}

struct TranscriptionStatus: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status", abstract: "Show the saved engine and Keychain credential status, without displaying the key.")
    func run() throws {
        let json: [String: Any] = ["engine": Config.transcriptionEngine(), "enabled": Config.transcriptionEnabled(),
            "cloud_audio": Config.transcriptionEngine() == "elevenlabs",
            "elevenlabs_key_saved": ElevenLabsKeychain.shared.containsKey(), "credential_storage": "macOS Keychain",
            "post_processing": Config.postProcessing().mode.rawValue]
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}

struct TranscriptionConfigure: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "configure", abstract: "Choose the engine for future transcription jobs. ElevenLabs uploads audio to its cloud API.")
    @Option var engine: TranscriptionEngineKind
    func run() throws {
        if engine == .elevenLabs && !ElevenLabsKeychain.shared.containsKey() {
            throw ValidationError("Save a key first with quill transcription key set or the Quill menu.")
        }
        guard Config.setTranscriptionEngine(engine) else { throw ValidationError("Could not save Quill's configuration.") }
        print("\(engine.title) will be used for the next transcription.")
    }
}

struct TranscriptionKey: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "key", abstract: "Manage the encrypted ElevenLabs API key in macOS Keychain.",
        subcommands: [TranscriptionKeySet.self, TranscriptionKeyRemove.self])
}

struct TranscriptionKeySet: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "set", abstract: "Save a key from a hidden terminal prompt or standard input. Never pass keys as command arguments.")
    @Flag(name: .customLong("stdin"), help: "Read the API key from standard input instead of a hidden prompt.") var fromStdin = false
    func run() throws {
        let key: String
        if fromStdin {
            let data = try FileHandle.standardInput.read(upToCount: 2048) ?? Data()
            guard data.count <= 1026, let input = String(data: data, encoding: .utf8) else { throw ValidationError("Invalid key input.") }
            key = input
        } else {
            guard isatty(STDIN_FILENO) == 1 else { throw ValidationError("Use --stdin when supplying the key through a pipe.") }
            guard let input = getpass("ElevenLabs API key: ") else { throw ValidationError("Could not read the API key.") }
            key = String(cString: input)
            memset(input, 0, strlen(input))
        }
        try ElevenLabsKeychain.shared.save(key)
        print("ElevenLabs API key saved in macOS Keychain.")
    }
}

struct TranscriptionKeyRemove: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "remove", abstract: "Remove the saved ElevenLabs API key from macOS Keychain.")
    func run() throws {
        try ElevenLabsKeychain.shared.remove()
        print("ElevenLabs API key removed. Select Parakeet or save another key to resume automatic transcription.")
    }
}

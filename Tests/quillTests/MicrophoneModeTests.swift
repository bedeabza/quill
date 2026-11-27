import XCTest
@testable import quill

@MainActor
final class MicrophoneModeTests: XCTestCase {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("quill-mic-mode-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root
    }

    func testSettingsDefaultPersistenceLegacyConfigAndRecordingSnapshot() throws {
        let root = try root(), config = root.appendingPathComponent("config.json")
        let key = ElevenLabsKeyStore(url: root.appendingPathComponent("unused-key"))
        let model = SettingsModel(appState: AppState(), keyStore: key, configURL: config)
        XCTAssertEqual(model.microphoneMode, .personal)
        try Data(#"{"shared_microphone":true,"other_setting":"preserved"}"#.utf8).write(to: config)
        model.reload()
        XCTAssertEqual(model.microphoneMode, .shared)
        try Data(#"{"files":{},"shared_microphone":true}"#.utf8).write(to: root.appendingPathComponent("meta.json"))
        model.microphoneMode = .personal
        XCTAssertNil(model.message)
        XCTAssertEqual(Config.microphoneMode(at: config), .personal)
        XCTAssertTrue(try SessionMeta.read(from: root).sharedMicrophone, "Existing session mode must not follow global settings")
        XCTAssertTrue(try String(contentsOf: config, encoding: .utf8).contains("preserved"))
        model.microphoneMode = .shared
        let reloaded = SettingsModel(appState: AppState(), keyStore: key, configURL: config)
        XCTAssertEqual(reloaded.microphoneMode, .shared)
    }

    func testFailedSaveKeepsSelectionAndMalformedConfigIntact() throws {
        let root = try root(), config = root.appendingPathComponent("config.json")
        let model = SettingsModel(appState: AppState(), keyStore: ElevenLabsKeyStore(url: root.appendingPathComponent("unused-key")), configURL: config)
        let invalid = Data("not-json".utf8)
        try invalid.write(to: config)
        model.microphoneMode = .shared
        XCTAssertEqual(model.microphoneMode, .personal)
        XCTAssertNotNil(model.message)
        XCTAssertEqual(try Data(contentsOf: config), invalid)
    }
}

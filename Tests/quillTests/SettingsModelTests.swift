import XCTest
@testable import quill

@MainActor
final class SettingsModelTests: XCTestCase {
    private var root: URL!
    private var store: ElevenLabsKeyStore!

    override func setUp() async throws {
        // Never the real Application Support folder.
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        store = ElevenLabsKeyStore(url: root.appendingPathComponent("Quill/elevenlabs-key"))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testKeyStateRoundTripWithoutKeepingTheKey() async throws {
        let model = SettingsModel(appState: AppState(), keyStore: store)
        XCTAssertEqual(model.keyState, .notSet)

        let saved = await model.saveKey("  test-secret-key-123456789\n")
        XCTAssertTrue(saved)
        XCTAssertEqual(model.keyState, .saved)
        XCTAssertNil(model.message)
        XCTAssertEqual(try store.read(), "test-secret-key-123456789")
        XCTAssertFalse(String(describing: Mirror(reflecting: model).children.map(\.value)).contains("test-secret-key"))

        let rejected = await model.saveKey("short")
        XCTAssertFalse(rejected)
        XCTAssertNotNil(model.message)
        XCTAssertEqual(model.keyState, .saved)

        await model.removeKey()
        XCTAssertEqual(model.keyState, .notSet)
        XCTAssertNil(try store.read())

        try FileManager.default.createDirectory(at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("test-secret-key-123456789".utf8).write(to: store.url)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: store.url.path)
        model.reload()
        guard case .problem(let problem) = model.keyState else { return XCTFail("Expected a key problem, got \(model.keyState)") }
        XCTAssertTrue(problem.contains("other user accounts"))
    }

    /// Refused before anything is written, so the real config stays untouched.
    /// Selecting an engine successfully writes ~/.config/quill/config.json and is not tested here.
    func testElevenLabsWithoutSavedKeyIsRefused() throws {
        let model = SettingsModel(appState: AppState(), keyStore: store)
        if model.engine == .elevenLabs { throw XCTSkip("The real config already selects ElevenLabs.") }
        let before = model.engine
        model.engine = .elevenLabs
        XCTAssertEqual(model.engine, before)
        XCTAssertEqual(model.message, "Save an ElevenLabs API key first.")
    }
}

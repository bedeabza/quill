import FluidAudio
import XCTest
@testable import quill

final class ParakeetEngineTests: XCTestCase, @unchecked Sendable {
    /// Optional on-device regression: supply en.aiff and ro.aiff containing
    /// the phrases in tools/test-transcription.sh. Never downloads in CI.
    func testAutomaticEnglishAndRomanianTranscription() async throws {
        guard let path = ProcessInfo.processInfo.environment["QUILL_TEST_AUDIO_DIR"] else {
            throw XCTSkip("Set QUILL_TEST_AUDIO_DIR to run local multilingual inference")
        }
        let cache = AsrModels.defaultCacheDirectory(for: ParakeetEngine.modelVersion)
        guard AsrModels.modelsExist(at: cache, version: ParakeetEngine.modelVersion) else {
            XCTFail("Cache the multilingual model before running the audio regression")
            return
        }
        let engine = ParakeetEngine()
        try await engine.prepare()
        do {
            // Reuse the same engine across language changes, as the queue does.
            let english = ["tomorrow", "project", "budget", "meeting"]
            let romanian = ["mâine", "bugetul", "proiectului", "ședință"]
            for (file, expected) in [("en", english), ("ro", romanian), ("en", english)] {
                let audio = URL(fileURLWithPath: path).appendingPathComponent("\(file).aiff")
                let segments = try await engine.transcribe(audio)
                let text = segments.map(\.text).joined(separator: " ").lowercased()
                print("\(file): \(text)")
                for word in expected {
                    XCTAssertTrue(text.contains(word), "Missing \(word) in \(file) transcript: \(text)")
                }
                XCTAssertFalse(segments.isEmpty)
                for segment in segments {
                    XCTAssertGreaterThanOrEqual(segment.start, 0)
                    XCTAssertGreaterThanOrEqual(segment.end, segment.start)
                }
            }
        } catch {
            await engine.release()
            throw error
        }
        await engine.release()
    }
}

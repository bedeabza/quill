import FluidAudio
import XCTest
@testable import quill

final class SpeakerDiarizerTests: XCTestCase, @unchecked Sendable {
    func testAutomaticPublicFourSpeakerMeeting() async throws {
        guard let path = ProcessInfo.processInfo.environment["QUILL_TEST_GROUP_AUDIO"] else {
            throw XCTSkip("Set QUILL_TEST_GROUP_AUDIO to an AMI four-speaker fixture")
        }
        ModelHub.offlineMode = true
        let result = try await SpeakerDiarizer.analyze(URL(fileURLWithPath: path), source: "system")
        let speakers = Set(result.turns.map(\.speaker_id))
        print("Group fixture: \(speakers.count) speakers, \(result.turns.count) turns")
        XCTAssertEqual(speakers.count, 4)
        XCTAssertTrue(result.turns.allSatisfy { $0.start >= 0 && $0.end > $0.start })
    }

    func testAutomaticThreeSpeakerMeeting() async throws {
        guard let path = ProcessInfo.processInfo.environment["QUILL_TEST_THREE_SPEAKERS"] else {
            throw XCTSkip("Set QUILL_TEST_THREE_SPEAKERS to the clean three-speaker fixture")
        }
        ModelHub.offlineMode = true
        let result = try await SpeakerDiarizer.analyze(URL(fileURLWithPath: path), source: "system")
        XCTAssertEqual(Set(result.turns.map(\.speaker_id)).count, 3)
    }

    func testOneAndTwoSpeakerControls() async throws {
        guard let directory = ProcessInfo.processInfo.environment["QUILL_TEST_SPEAKER_CONTROLS"] else {
            throw XCTSkip("Set QUILL_TEST_SPEAKER_CONTROLS for one- and two-speaker controls")
        }
        ModelHub.offlineMode = true
        for (file, count) in [("quill-one-speaker.wav", 1), ("quill-two-speakers.wav", 2)] {
            let result = try await SpeakerDiarizer.analyze(URL(fileURLWithPath: directory).appendingPathComponent(file), source: "system")
            XCTAssertEqual(Set(result.turns.map(\.speaker_id)).count, count, file)
        }
    }

}

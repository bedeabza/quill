import AVFoundation
import XCTest
@testable import quill

final class TranscriptPlaybackTests: XCTestCase {
    private func directory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("quill-playback-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func turn(_ id: Int, _ start: Double, _ end: Double) -> TranscriptTurn {
        TranscriptTurn(id: id, start: start, end: end, speaker: "Speaker \(id)", text: "")
    }

    func testActiveTurnFollowsTimeThroughGapsAndOverlaps() {
        // 1 is interrupted by 2; a pause follows 3.
        let turns = [turn(0, 1, 4), turn(1, 5, 12), turn(2, 7, 8), turn(3, 13, 15), turn(4, 20, 22)]
        let active = { TranscriptPlayback.activeTurn(turns, at: $0) }
        XCTAssertNil(active(0.5), "nothing before the first turn")
        XCTAssertEqual(active(1), 0)
        XCTAssertEqual(active(4.5), 0, "a pause keeps the last turn")
        XCTAssertEqual(active(6), 1)
        XCTAssertEqual(active(7.5), 2, "the interjection wins while it lasts")
        XCTAssertEqual(active(9), 1, "then the longer turn again")
        XCTAssertEqual(active(12.5), 1, "a pause keeps the turn that ended last, not an earlier interjection")
        XCTAssertEqual(active(17), 3)
        XCTAssertEqual(active(30), 4, "after the end, the last turn")
        XCTAssertNil(TranscriptPlayback.activeTurn([], at: 3))
    }

    func testSourcePrefersTheMeetingMixAndOtherwiseOffsetsTheTracks() throws {
        let dir = try directory()
        XCTAssertEqual(TranscriptPlayback.source(in: dir),
                       .unavailable("Its meta.json is missing or unreadable, so the audio can’t be lined up with the transcript."))
        try Data(#"{"files":{"mic":"mic.caf","system":"system.caf"},"start_offset_ms":{"mic":468,"system":0}}"#.utf8)
            .write(to: dir.appendingPathComponent("meta.json"))
        XCTAssertEqual(TranscriptPlayback.source(in: dir), .unavailable("Its audio files are missing or unreadable."))
        try AudioTestSupport.write(dir.appendingPathComponent("system.caf"))
        XCTAssertEqual(TranscriptPlayback.source(in: dir), .tracks([.init(url: dir.appendingPathComponent("system.caf"), offset: 0)]))
        try AudioTestSupport.write(dir.appendingPathComponent("mic.caf"))
        XCTAssertEqual(TranscriptPlayback.source(in: dir), .tracks([.init(url: dir.appendingPathComponent("mic.caf"), offset: 0.468),
                                                                    .init(url: dir.appendingPathComponent("system.caf"), offset: 0)]))
        try AudioTestSupport.write(dir.appendingPathComponent(MeetingAudio.filename))
        XCTAssertEqual(TranscriptPlayback.source(in: dir), .tracks([.init(url: dir.appendingPathComponent(MeetingAudio.filename), offset: 0)]))
    }

    /// The player follows the selection: playing from a turn loads that
    /// recording, and selecting another one or leaving the section stops it.
    @MainActor
    func testPlayingFromATurnStopsWhenTheSelectionChangesOrTheSectionCloses() async throws {
        let root = RecordingsLibrary.canonicalDirectory(try directory())
        for name in ["2026.11.02-1000", "2026.11.03-1000"] {
            let dir = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
            try Data(#"{"files":{"mic":"mic.caf"},"start_offset_ms":{"mic":0}}"#.utf8).write(to: dir.appendingPathComponent("meta.json"))
            // Silence, so the test makes no sound.
            try AudioTestSupport.write(dir.appendingPathComponent("mic.caf"), samples: [Int16](repeating: 0, count: 48_000))
            try Transcript(engine: "parakeet", model: "fixture", created_at: "fixture", segments: [
                .init(speaker: "me", start_ms: 0, end_ms: 1000, text: "First."),
                .init(speaker: "them", start_ms: 1500, end_ms: 2800, text: "Second.")]).write(to: dir)
        }
        let model = RecordingsModel(root: root, transcription: TranscriptionCoordinator())
        func until(_ condition: () -> Bool) async throws {
            for _ in 0..<300 where !condition() { try await Task.sleep(nanoseconds: 10_000_000) }
            XCTAssertTrue(condition())
        }
        model.refresh()
        try await until { model.playback != nil && model.transcript != nil }
        guard case .turns(let turns) = model.transcript else { return XCTFail("no turns") }
        let selected = try XCTUnwrap(model.selection)
        XCTAssertEqual(model.playback, .tracks([.init(url: selected.appendingPathComponent("mic.caf"), offset: 0)]))

        model.play(from: turns[1])
        XCTAssertEqual(model.player.directory, selected)
        XCTAssertEqual(model.player.activeTurn, 1, "the clicked turn is highlighted at once")
        try await until { model.player.duration > 0 }
        XCTAssertEqual(model.player.duration, 3, accuracy: 0.01)

        model.selection = root.appendingPathComponent(selected.lastPathComponent == "2026.11.02-1000" ? "2026.11.03-1000" : "2026.11.02-1000")
        XCTAssertNil(model.player.directory, "another recording stops playback")
        XCTAssertNil(model.player.activeTurn)

        try await until { model.playback != nil && model.transcript != nil }
        guard case .turns(let other) = model.transcript else { return XCTFail("no turns") }
        model.play(from: other[0])
        XCTAssertNotNil(model.player.directory)
        model.stop()
        XCTAssertNil(model.player.directory, "closing the window or leaving Recordings stops playback")
    }

    /// Renders the composition and checks a late-starting track is heard only
    /// from its offset, as `MeetingAudio` places it.
    func testCompositionPlaysEachTrackFromItsOffset() async throws {
        let dir = try directory(), rate = 16_000
        let tone = (0..<rate).map { Int16(8000 * sin(Double($0) * 2 * .pi * 440 / Double(rate))) }
        try AudioTestSupport.write(dir.appendingPathComponent("system.caf"))
        try AudioTestSupport.write(dir.appendingPathComponent("mic.caf"), samples: tone)
        let composition = try await TranscriptPlayback.composition([.init(url: dir.appendingPathComponent("mic.caf"), offset: 0.5),
                                                                    .init(url: dir.appendingPathComponent("system.caf"), offset: 0)])
        XCTAssertEqual(composition.duration.seconds, 1.5, accuracy: 0.01)

        let reader = try AVAssetReader(asset: composition)
        let output = AVAssetReaderAudioMixOutput(audioTracks: try await composition.loadTracks(withMediaType: .audio), audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false])
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var samples: [Int16] = []
        while let buffer = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(buffer) {
            var data = Data(count: CMBlockBufferGetDataLength(block))
            _ = data.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
            samples += data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        }
        let firstSound = try XCTUnwrap(samples.firstIndex { abs(Int($0)) > 1000 })
        XCTAssertEqual(Double(firstSound) / Double(rate), 0.5, accuracy: 0.01)
        XCTAssertEqual(Double(samples.count) / Double(rate), 1.5, accuracy: 0.01)
    }
}

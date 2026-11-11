import AVFoundation
import XCTest
@testable import quill

final class MicTrackTests: XCTestCase {
    private func tone(rate: Double, seconds: Double) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        let count = AVAudioFrameCount(rate * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count)!
        buffer.frameLength = count
        for i in 0..<Int(count) { buffer.floatChannelData![0][i] = 0.5 * sin(2 * .pi * 440 * Float(i) / Float(rate)) }
        return buffer
    }

    private func makeTrack(_ url: URL) throws -> MicTrack {
        MicTrack(file: try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true],
            commonFormat: .pcmFormatFloat32, interleaved: false))
    }

    private func rms(_ samples: ArraySlice<Float>) -> Float {
        (samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
    }

    /// 2026.11.11-1136: AirPods connected mid-call and the microphone track
    /// ended there. A restart on a 24 kHz input continues the same track, with
    /// the switch-over written as silence so it stays on the meeting clock.
    func testRestartOnAnotherInputKeepsOneTrackOnTheMeetingClock() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mic-track-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        var gaps: [MicTrack.Gap] = []
        try autoreleasepool {
            let track = try makeTrack(url)
            let t0 = 1_000.0
            for i in 0..<10 { try track.append(tone(rate: 48_000, seconds: 0.1), at: t0 + Double(i) * 0.1) }
            track.resume()
            for i in 0..<10 { try track.append(tone(rate: 24_000, seconds: 0.1), at: t0 + 3.5 + Double(i) * 0.1) }
            gaps = track.finish(at: t0 + 4.6)
        }
        XCTAssertEqual(gaps.count, 1)
        XCTAssertEqual(gaps[0].start, 1.0, accuracy: 0.001)
        XCTAssertEqual(gaps[0].end, 3.5, accuracy: 0.001)

        let file = try AVAudioFile(forReading: url)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        // 4.5 s at 48 kHz, less the resampler's filter latency (20 ms) still held at the end.
        XCTAssertLessThanOrEqual(samples.count, 216_000)
        XCTAssertGreaterThan(samples.count, 216_000 - 2_048)
        XCTAssertGreaterThan(rms(samples[0..<48_000]), 0.3)
        XCTAssertEqual(rms(samples[48_000..<168_000]), 0)
        // The resampled 440 Hz tone keeps its level.
        XCTAssertEqual(rms(samples[170_000..<210_000]), Float(0.5 / 2.0.squareRoot()), accuracy: 0.03)
    }

    func testEarlyStopIsATrailingGapAndAShortTailIsNot() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mic-track-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        try autoreleasepool {
            let track = try makeTrack(url)
            try track.append(tone(rate: 48_000, seconds: 2), at: 10)
            XCTAssertEqual(track.finish(at: 12.3), [])
            XCTAssertEqual(track.finish(at: 40), [MicTrack.Gap(start: 2, end: 30)])
        }
    }

    func testGapsReadFromMetaOrDerivedFromAnOlderShortTrack() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mic-gaps-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let meta = dir.appendingPathComponent("meta.json")

        try AudioTestSupport.write(dir.appendingPathComponent("mic.caf"), samples: [Int16](repeating: 0, count: 16_000 * 6))
        try JSONSerialization.data(withJSONObject: ["duration_seconds": 2383, "files": ["mic": "mic.caf", "system": "system.caf"],
                                                    "start_offset_ms": ["mic": 500, "system": 0]]).write(to: meta)
        let derived = MicrophoneGaps.read(in: dir)
        XCTAssertEqual(derived, [MicTrack.Gap(start: 6.5, end: 2383)])
        XCTAssertEqual(MicrophoneGaps.notice(derived, duration: 2383), "Microphone stopped at 0:06. Your voice after that wasn’t recorded.")

        try JSONSerialization.data(withJSONObject: ["duration_seconds": 3700, "files": ["mic": "mic.caf"],
            "microphone_gaps": [["start": 387.5, "end": 389.1], ["start": 1200, "end": 1260.25], ["start": 3600, "end": 3700]]]).write(to: meta)
        let stored = MicrophoneGaps.read(in: dir)
        XCTAssertEqual(stored.count, 3)
        XCTAssertEqual(MicrophoneGaps.notice(stored, duration: 3700),
                       "Microphone not recorded 20:00–21:00, 1:00:00–1:01:40. Your voice in that time wasn’t recorded.")
        XCTAssertEqual(MicrophoneGaps.log(stored), "microphone not recorded (meeting clock): 387.5–389.1 s, 1200.0–1260.2 s, 3600.0–3700.0 s")

        try JSONSerialization.data(withJSONObject: ["duration_seconds": 3700, "files": ["mic": "mic.caf"], "microphone_gaps": []]).write(to: meta)
        XCTAssertEqual(MicrophoneGaps.read(in: dir), [], "a measured recording is never re-derived from the track length")
        XCTAssertNil(MicrophoneGaps.notice([MicTrack.Gap(start: 387.5, end: 389.1)], duration: 3700))
    }
}

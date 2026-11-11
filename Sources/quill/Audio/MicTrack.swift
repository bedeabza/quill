import AVFoundation
import Foundation

/// The microphone track of one recording, kept on the meeting clock while
/// capture restarts on other inputs (AirPods connecting or leaving, the default
/// input changing). Every buffer is converted to the file's format, and the
/// time the microphone was away is written as silence, so `mic.caf` stays
/// aligned with `system.caf`. Gaps are measured on the host clock between the
/// end of the last buffer and the first buffer after a restart.
final class MicTrack: @unchecked Sendable {
    struct Gap: Equatable, Sendable {
        /// Seconds from the track's first sample.
        var start: Double
        var end: Double
    }

    /// An early stop shorter than this is the last buffer still in flight.
    static let trailingTolerance = 1.0

    let format: AVAudioFormat
    private let file: AVAudioFile
    private let lock = NSLock()
    private var frames: Int64 = 0
    private var lastEnd: Double?
    private var resuming = false
    private var converter: AVAudioConverter?
    private var gaps: [Gap] = []

    init(file: AVAudioFile) {
        self.file = file
        format = file.processingFormat
    }

    /// Appends a buffer whose first sample was captured at `time` (host-clock
    /// seconds), in any PCM format.
    func append(_ buffer: AVAudioPCMBuffer, at time: Double) throws {
        try lock.withLock {
            if resuming, let lastEnd {
                let missing = Int64(((time - lastEnd) * format.sampleRate).rounded())
                if missing > 0 {
                    gaps.append(Gap(start: seconds(frames), end: seconds(frames + missing)))
                    try writeSilence(missing)
                }
            }
            resuming = false
            lastEnd = time + Double(buffer.frameLength) / buffer.format.sampleRate
            try write(converted(buffer))
        }
    }

    /// Capture stopped; the next buffer may come from another input.
    func resume() {
        lock.withLock {
            resuming = true
            converter = nil
        }
    }

    /// The recording ended at `time`: a capture that stopped early leaves a
    /// trailing gap. Returns every gap, in track seconds.
    func finish(at time: Double) -> [Gap] {
        lock.withLock {
            if let lastEnd, time - lastEnd >= Self.trailingTolerance {
                gaps.append(Gap(start: seconds(frames), end: seconds(frames) + time - lastEnd))
            }
            return gaps
        }
    }

    private func seconds(_ frames: Int64) -> Double { Double(frames) / format.sampleRate }

    private func write(_ buffer: AVAudioPCMBuffer) throws {
        guard buffer.frameLength > 0 else { return }
        try file.write(from: buffer)
        frames += Int64(buffer.frameLength)
    }

    private func writeSilence(_ count: Int64) throws {
        let chunk = AVAudioFrameCount(format.sampleRate)
        guard let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { return }
        for channel in 0..<Int(format.channelCount) {
            silence.floatChannelData.map { memset($0[channel], 0, Int(chunk) * MemoryLayout<Float>.size) }
        }
        var left = count
        while left > 0 {
            silence.frameLength = AVAudioFrameCount(min(Int64(chunk), left))
            try write(silence)
            left -= Int64(silence.frameLength)
        }
    }

    /// Resamples another device's buffers; the converter keeps its filter
    /// state across buffers of one capture and is dropped on restart.
    private func converted(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        if buffer.format == format { return buffer }
        if converter?.inputFormat != buffer.format { converter = AVAudioConverter(from: buffer.format, to: format) }
        let ratio = format.sampleRate / buffer.format.sampleRate
        guard let converter, let output = AVAudioPCMBuffer(pcmFormat: format,
            frameCapacity: AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64) else {
            throw MicRecorder.RecorderError.formatUnsupported(buffer.format)
        }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            if supplied { state.pointee = .noDataNow; return nil }
            supplied = true
            state.pointee = .haveData
            return buffer
        }
        if status == .error { throw error ?? MicRecorder.RecorderError.formatUnsupported(buffer.format) }
        return output
    }
}

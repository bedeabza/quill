import AVFoundation
import Foundation

enum AudioTestSupport {
    static func write(_ url: URL, samples: [Int16] = [Int16](repeating: 0, count: 16_000)) throws {
        try autoreleasepool {
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for i in samples.indices { buffer.int16ChannelData![0][i] = samples[i] }
        try file.write(from: buffer)
        }
    }
    static func read(_ url: URL) throws -> [Int16] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16_384)!
        var samples: [Int16] = []
        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: AVAudioFrameCount(min(16_384, file.length - file.framePosition)))
            guard buffer.frameLength > 0 else { throw CocoaError(.fileReadCorruptFile) }
            samples += UnsafeBufferPointer(start: buffer.int16ChannelData![0], count: Int(buffer.frameLength))
        }
        return samples
    }
}

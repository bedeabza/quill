import Foundation

enum TranscriptionEngineKind: String, CaseIterable, Sendable {
    case parakeet
    case elevenLabs = "elevenlabs"

    var title: String {
        switch self {
        case .parakeet: return "Parakeet v3 (local)"
        case .elevenLabs: return "ElevenLabs Scribe v2 (cloud)"
        }
    }
}

struct TranscriptionFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// One timed span of recognized speech from a single track, relative to that
/// track's own start.
struct TranscriptSegment: Sendable {
    let start: TimeInterval
    let end: TimeInterval
    let text: String
    var words: [TranscriptWord] = []
}

struct TranscriptWord: Sendable {
    let start: TimeInterval
    let end: TimeInterval
    let text: String
}

/// A local or cloud speech-to-text engine. Engines are prepared lazily
/// (model download + load) when the transcription queue has work and released
/// when it drains, so quill never idles holding gigabytes of model weights.
protocol TranscriptionEngine: Sendable {
    /// Short engine identifier recorded as transcript.json provenance.
    var name: String { get }
    /// Concrete model identifier recorded as transcript.json provenance.
    var model: String { get }
    func prepare() async throws
    func transcribe(_ audio: URL) async throws -> [TranscriptSegment]
    func release() async
}

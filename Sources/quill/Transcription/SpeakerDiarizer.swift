import FluidAudio
import Foundation

struct SpeakerAnalysis: Codable, Sendable {
    var model = "pyannote-community-1-wespeaker-vbx"
    var turns: [SpeakerTurn]
    var names: [String: SpeakerIdentity]
    var named_spans: [NamedSpeakerSpan] = []
    var voice_identities: [String: SpeakerIdentity]? = nil
    var voice_samples: [VoiceSample]? = nil
}

enum SpeakerDiarizer {
    static var defaultConfiguration: OfflineDiarizerConfig {
        var config = OfflineDiarizerConfig.default
        // FluidAudio 0.15.5's 0.8 prior merged distinct short speaking turns.
        // 0.2 preserves the voices in our three- and four-person regressions.
        config.clustering.warmStartFb = 0.2
        return config
    }

    static func analyze(_ audio: URL, source: String, speakerCount: Int? = nil,
                        configuration: OfflineDiarizerConfig = defaultConfiguration, captureVoiceSamples: Bool = false) async throws -> SpeakerAnalysis {
        var config = speakerCount.map { configuration.withSpeakers(exactly: $0) } ?? configuration
        config.exposeChunkEmbeddings = captureVoiceSamples
        let manager = OfflineDiarizerManager(config: config)
        let result = try await manager.process(audio)
        // IDs are stable for this analysis and deliberately scoped to the track.
        let ids = Set(result.segments.map(\.speakerId)).sorted()
        let mapping = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($0.element, "\(source)_\($0.offset + 1)") })
        let turns = result.segments.compactMap { segment -> SpeakerTurn? in
            let start = Double(segment.startTimeSeconds), end = Double(segment.endTimeSeconds)
            guard start.isFinite, end.isFinite, start >= 0, end > start, let id = mapping[segment.speakerId] else { return nil }
            return SpeakerTurn(speaker_id: id, start: start, end: end)
        }.sorted { $0.start < $1.start }
        let samples = result.chunkEmbeddings?.compactMap { chunk -> VoiceSample? in
            guard let id = mapping[chunk.speakerId] else { return nil }
            return VoiceSample(speaker_id: id, start: chunk.startTimeSeconds, end: chunk.endTimeSeconds, embedding: chunk.embedding256)
        }
        return SpeakerAnalysis(turns: turns, names: [:], voice_samples: samples.map { VoiceMemory.cleanSamples($0, turns: turns) })
    }
}

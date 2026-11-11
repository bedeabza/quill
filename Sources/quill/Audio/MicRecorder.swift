import AVFoundation
import CoreAudio
import Foundation

/// Records the default input device to a file via AVAudioEngine, encoding AAC
/// mono. Buffers stream straight to disk — nothing is held in memory, so
/// session length is unbounded.
///
/// With voice processing on, Apple's echo canceller subtracts speaker playback
/// from the mic so the system track doesn't bleed into the mic track.
/// VoiceProcessingIO is a duplex unit, not an input effect: it needs a rendered
/// output path and one explicit mono client format on both sides, or it
/// silently delivers zeroed buffers (rca-001). A first-second liveness check
/// catches routes where even the correct graph stays silent and restarts
/// capture raw.
///
/// The engine stops when the input changes (AirPods connecting or leaving, a
/// new default input). Capture then restarts on the current default input and
/// keeps writing the same track; `MicTrack` fills the time in between with
/// silence and reports it as a gap.
final class MicRecorder: @unchecked Sendable {
    enum RecorderError: Error, CustomStringConvertible {
        case engineStartFailed(Error)
        case fileCreationFailed(Error)
        case formatUnsupported(AVAudioFormat)

        var description: String {
            switch self {
            case .engineStartFailed(let e): return "mic engine start failed: \(e)"
            case .fileCreationFailed(let e): return "mic file creation failed: \(e)"
            case .formatUnsupported(let f): return "can't downmix mic format \(f)"
            }
        }
    }

    /// Restarts beyond this many per minute wait for the minute to pass, so a
    /// route that keeps reconfiguring itself cannot loop.
    private static let restartLimit = 10

    private var engine = AVAudioEngine()
    private var track: MicTrack?
    private var url: URL?
    private(set) var isRecording = false
    /// Wall-clock time of the first captured buffer — the track's true start,
    /// used to offset-align the two tracks' transcript timestamps.
    private(set) var firstBufferAt: Date?
    /// Time the microphone was not recorded, in track seconds; set by `stop()`.
    private(set) var gaps: [MicTrack.Gap] = []

    private var voiceProcessing = false
    private var inputDevice: AudioDeviceID?
    private var configurationObserver: NSObjectProtocol?
    private var defaultInputListener: AudioObjectPropertyListenerBlock?
    private var pendingRestart: DispatchWorkItem?
    private var restarts: [Date] = []

    // Liveness check state (voice-processing path only). Written from the tap
    // callback, read on main when deciding to fall back.
    private var livenessFrames = 0
    private var livenessPeak: Float = 0
    private var livenessSettled = false

    /// Start capturing the mic, encoding AAC into `url` (use a .caf extension
    /// — CAF needs no finalization pass, so a crash loses nothing written).
    func start(writingTo url: URL) throws {
        guard !isRecording else { return }
        self.url = url
        gaps = []
        voiceProcessing = Config.micVoiceProcessing()
        try attach(voiceProcessing: voiceProcessing)
        isRecording = true
        listenForDefaultInput()
    }

    /// Stop capturing and finalize the file. Idempotent.
    func stop() {
        guard isRecording else { return }
        isRecording = false
        pendingRestart?.cancel()
        stopListeningForDefaultInput()
        detach()
        gaps = track?.finish(at: Self.now()) ?? []
        track = nil
    }

    // MARK: -

    /// Build the engine graph on the current default input and start capture,
    /// creating the AAC file on the first call. Called at start, after an
    /// input change, and with voiceProcessing: false if the liveness check trips.
    private func attach(voiceProcessing: Bool) throws {
        engine = AVAudioEngine()
        let input = engine.inputNode

        var voice = voiceProcessing
        if voice {
            do {
                try input.setVoiceProcessingEnabled(true)
                // The live voice unit makes macOS treat the session like a
                // call and duck all other audio — meetings played through the
                // speakers would get quieter the moment recording starts.
                input.voiceProcessingOtherAudioDuckingConfiguration =
                    .init(enableAdvancedDucking: false, duckingLevel: .min)
            } catch {
                FileHandle.standardError.write(Data(
                    "warning: mic voice processing unavailable (\(error)) — recording raw mic\n".utf8
                ))
                voice = false
            }
        }
        let inputFormat = input.outputFormat(forBus: 0)
        // Mid-switch the input can report 0 Hz or no channels; connecting or
        // tapping that format raises an exception Swift cannot catch.
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw RecorderError.formatUnsupported(inputFormat)
        }

        // One explicit mono client format. With voice processing this is the
        // Voice I/O boundary format on both sides of the duplex unit — never
        // accept the inherited multichannel route format (a 9-channel device
        // yielded digital silence). Raw capture downmixes to the same shape;
        // speech models want one channel anyway.
        guard let monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: inputFormat.sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw RecorderError.formatUnsupported(inputFormat)
        }

        if track == nil {
            // The first input's rate is the track's rate; later inputs are
            // resampled to it.
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: monoFormat.sampleRate,
                AVNumberOfChannelsKey: 1,
            ]
            do {
                track = MicTrack(file: try AVAudioFile(
                    forWriting: url!,
                    settings: settings,
                    commonFormat: monoFormat.commonFormat,
                    interleaved: monoFormat.isInterleaved
                ))
            } catch {
                throw RecorderError.fileCreationFailed(error)
            }
        }

        if voice {
            // Complete the duplex graph: VoiceProcessingIO must render to an
            // output device or the input side never produces audio. The mixer
            // has no sources — nothing is monitored or played — its connection
            // exists solely to give the unit a formatted output path.
            engine.connect(engine.mainMixerNode, to: engine.outputNode, format: monoFormat)
            livenessFrames = 0
            livenessPeak = 0
            livenessSettled = false
            installVoiceTap(on: input, format: monoFormat)
        } else {
            try installRawTap(on: input, inputFormat: inputFormat, monoFormat: monoFormat)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw RecorderError.engineStartFailed(error)
        }
        inputDevice = Self.defaultInputDevice()
        let engine = engine
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            // A route change the engine survived needs nothing, nor a
            // notification already queued for an engine since replaced.
            guard let self, engine === self.engine,
                  !engine.isRunning || engine.inputNode.outputFormat(forBus: 0) != inputFormat else { return }
            self.scheduleRestart("input configuration changed")
        }

        let report = "mic: voiceProcessing=\(input.isVoiceProcessingEnabled) "
            + "input=\(input.outputFormat(forBus: 0)) tap=\(monoFormat)\n"
        FileHandle.standardError.write(Data(report.utf8))
    }

    private func detach() {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
    }

    /// Writes one buffer at the host time of its first sample.
    private func capture(_ buffer: AVAudioPCMBuffer, at when: AVAudioTime) {
        if firstBufferAt == nil { firstBufferAt = Date() }
        let time = when.isHostTimeValid ? AVAudioTime.seconds(forHostTime: when.hostTime) : Self.now()
        do {
            try track?.append(buffer, at: time)
        } catch {
            FileHandle.standardError.write(Data("mic track write failed: \(error)\n".utf8))
        }
    }

    /// Voice-processing path: the unit converts to the mono client format
    /// itself, so tapped buffers write straight to the track. Tracks signal
    /// peak over the first second — an unsupported route (device pair, macOS
    /// AUVPAggregate defects) delivers callbacks full of digital zeros, and
    /// the only recovery is restarting raw.
    private func installVoiceTap(on input: AVAudioInputNode, format: AVAudioFormat) {
        let checkFrames = Int(format.sampleRate)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, when in
            guard let self else { return }
            if !self.livenessSettled {
                let frames = Int(buffer.frameLength)
                if let data = buffer.floatChannelData?[0] {
                    for i in 0..<frames {
                        self.livenessPeak = max(self.livenessPeak, abs(data[i]))
                    }
                }
                self.livenessFrames += frames
                if self.livenessFrames >= checkFrames {
                    self.livenessSettled = true
                    if self.livenessPeak == 0 {
                        let engine = self.engine
                        DispatchQueue.main.async { if engine === self.engine { self.fallBackToRaw() } }
                    }
                }
            }
            self.capture(buffer, at: when)
        }
    }

    /// Raw path: tap at the device's native format and downmix to mono. Same
    /// sample rate on both sides, so the one-shot convert applies.
    private func installRawTap(
        on input: AVAudioInputNode,
        inputFormat: AVAudioFormat,
        monoFormat: AVAudioFormat
    ) throws {
        guard let converter = AVAudioConverter(from: inputFormat, to: monoFormat) else {
            throw RecorderError.formatUnsupported(inputFormat)
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, when in
            guard let self, let mono = AVAudioPCMBuffer(
                pcmFormat: monoFormat,
                frameCapacity: buffer.frameCapacity
            ) else { return }
            do {
                try converter.convert(to: mono, from: buffer)
            } catch {
                FileHandle.standardError.write(Data("mic track write failed: \(error)\n".utf8))
                return
            }
            self.capture(mono, at: when)
        }
    }

    /// The voice-processing route delivered a full second of digital silence:
    /// restart raw for the rest of this input. The silent second stays in the
    /// track, so its timestamps are unchanged.
    private func fallBackToRaw() {
        guard isRecording else { return }
        FileHandle.standardError.write(Data(
            "warning: voice processing delivered silence — restarting mic raw\n".utf8
        ))
        if !restart(voiceProcessing: false) { scheduleRestart("raw restart failed", after: 1, attempt: 1) }
    }

    // MARK: Input changes

    /// Coalesces the burst of notifications one device change produces. A
    /// restart that fails (a Bluetooth input still connecting) is retried
    /// after 1, 2, then every 5 seconds; one over the cap waits until the
    /// oldest restart leaves the minute. So the input's last state is always
    /// tried while recording.
    private func scheduleRestart(_ reason: String, after delay: Double = 0.3, attempt: Int = 0) {
        guard isRecording else { return }
        pendingRestart?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isRecording else { return }
            let now = Date()
            self.restarts = self.restarts.filter { now.timeIntervalSince($0) < 60 }
            if self.restarts.count >= Self.restartLimit, let oldest = self.restarts.first {
                let wait = 60 - now.timeIntervalSince(oldest) + 0.1
                FileHandle.standardError.write(Data("warning: mic \(reason) — too many restarts this minute, trying again in \(Int(wait.rounded(.up))) s\n".utf8))
                self.scheduleRestart(reason, after: wait, attempt: attempt)
                return
            }
            self.restarts.append(now)
            FileHandle.standardError.write(Data("mic: \(reason) — restarting capture on the current input\n".utf8))
            if !self.restart(voiceProcessing: self.voiceProcessing) {
                self.scheduleRestart(reason, after: [1.0, 2.0, 5.0][min(attempt, 2)], attempt: attempt + 1)
            }
        }
        pendingRestart = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Until a restart succeeds, the time is a gap in the track.
    private func restart(voiceProcessing: Bool) -> Bool {
        detach()
        track?.resume()
        do {
            try attach(voiceProcessing: voiceProcessing)
            return true
        } catch {
            FileHandle.standardError.write(Data("mic restart failed: \(error)\n".utf8))
            return false
        }
    }

    private static func defaultInputAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                   mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    /// A new default input may not stop the engine (the old device is still
    /// there), so it is watched separately.
    private func listenForDefaultInput() {
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, Self.defaultInputDevice() != self.inputDevice else { return }
            self.scheduleRestart("default input changed")
        }
        var address = Self.defaultInputAddress()
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener) == noErr {
            defaultInputListener = listener
        }
    }

    private func stopListeningForDefaultInput() {
        guard let listener = defaultInputListener else { return }
        var address = Self.defaultInputAddress()
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
        defaultInputListener = nil
    }

    private static func defaultInputDevice() -> AudioDeviceID? {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = defaultInputAddress()
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else { return nil }
        return device
    }

    private static func now() -> Double { AVAudioTime.seconds(forHostTime: mach_absolute_time()) }
}

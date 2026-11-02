# Single-recording ElevenLabs pipeline

Implemented November 2, 2026.

## Behavior

The original `mic.caf` and `system.caf` remain unchanged. Quill converts declared
inputs to 16 kHz mono PCM, pads their saved start offsets onto the meeting clock,
and uses the system recording as the playback reference for SpeexDSP's echo
canceller. Cleaned microphone and direct system audio are mixed at half gain
each into `meeting-audio.wav`. A single declared input is aligned at unity gain
without echo cancellation. Missing, empty or invalid declared inputs fail
before upload; partial meetings are not silently sent.

The app bundles the unmodified echo-cancellation subset of SpeexDSP 1.2.1 with
KISS FFT. Source provenance and checksum are in `Sources/QuillEchoDSP/vendor/README.quill`.
No extra program or model download is needed. The 256-sample frame, 4096-sample
filter operates at 16 kHz. No denoiser, gain-control stage or local speaker model
is used. Original audio outside the mic's recorded interval is not passed
through the adaptive filter's predicted echo. PCM writing is finalized and the
full frame count is checked before publication. Mixing uses bounded streaming
buffers; it does not load an entire meeting into memory.

The preparation manifest includes source checksums and offsets, preparation
version, combined checksum/frame count, energy diagnostics and conservative
local-only/remote-only windows. Unchanged inputs reuse that waveform and its
`elevenlabs-meeting-audio.wav.json` response. Old per-track responses cannot
satisfy the combined cache, but remain available for audit and legacy speaker
refresh. A fresh regeneration invalidates only the combined response. App
regeneration backs up prepared files too and restores them with the transcript
on failure. An accepted request without a received response may still incur a
billed retry; one pipeline upload does not provide exactly-once network delivery.

Scribe assigns one set of speaker IDs across the entire meeting. Original
transcripts preserve those anonymous IDs and use source `meeting`. Every mixed
speaker must meet 95% agreement by observed speech duration to publish the
separate named variant. Source-only windows gate corresponding UI evidence;
uncertain/overlapping windows do not vote. Actual local tile observations are
saved separately in `local_names`, so legacy remote-track attribution never
consumes them. Meet's explicit local `Name (You)` labels retain the name;
plain `You` remains unknown. Shared-mic local tiles cannot name individuals.
No local name is assigned merely from the microphone configuration. A pure
ElevenLabs transcript is still saved when names cannot be established.

## Validation

- Debug/release builds and packaged signature verification.
- Standalone regression runner against actual production objects: 76 scenarios,
  including the existing Scribe, browser, engine, permissions and Meet tile
  cases. HTTP and credentials are mocked; no validation upload was made.
- New coverage: exactly one HTTP upload for two input tracks, cache reuse and
  source invalidation, unified speaker IDs, delayed/reflected echo with
  simultaneous independent local audio, exact offsets/unequal ends/silence,
  capture boundaries, original preservation, corrupt prepared caches, rollback,
  fresh/legacy cache isolation, offline mixed refresh and name-evidence gating.
- Synthetic echo fixture: residual energy ratio about 0.000075 after adaptation
  and local-signal projection gain about 0.96 during double talk. These are
  synthetic signal measurements, not a claim about meeting diarization accuracy.
- Full November 2 12:03 recording prepared in a separate private temporary
  folder: 3710.697 seconds of captured audio, roughly 51–72 seconds with the debug
  build. Original capture hashes remained unchanged; prepared cache validated.
  No transcription engine, real Keychain credential or network request was used.
- Offscreen browser checks cover search, named previews, regeneration controls
  and the revised upload explanation at 1040/860-point widths.
- Full XCTest execution is unavailable on this host (Command Line Tools without
  XCTest). Recorded-meeting speaker accuracy still requires a new Scribe result.

Echo cancellation is best effort. Saturation, non-linear speaker processing,
room acoustics, capture-clock drift and overlapping voices may leave residual
echo. Speaker count is still inferred by Scribe; it is not forced to seven.
Missing live meeting observations cannot be reconstructed from the audio mix.

References: [Speex echo-cancellation API](https://www.speex.org/docs/manual/speex-manual/node7.html),
[official SpeexDSP release](https://downloads.xiph.org/releases/speex/speexdsp-1.2.1.tar.gz).

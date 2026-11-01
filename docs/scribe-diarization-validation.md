# Scribe diarization and timeline name mapping

Validated November 1, 2026.

## Behavior

- ElevenLabs requests Scribe v2 diarization and retains each word's provider
  speaker ID. Speaker changes split segments even within a sentence. IDs are
  scoped to their track and readable numbers are unique across tracks.
- The ElevenLabs coordinator never invokes local diarization, voice memory,
  participant-roster relabeling or automatic transcript cleanup. Explicit
  speaker refresh also never invokes local models. Voice-memory learning rejects
  ElevenLabs recordings before reading audio or loading models.
- The canonical `transcript.json` / `transcript.md` remains anonymous. A separate
  `transcript-named.json` / `transcript-named.md` is written only when every
  remote speaker has at least 95% agreement with one name by observed speech
  duration. Missing evidence or unknown provider IDs fail the gate.
- UI snapshots support bounded 250 ms windows. Missing observations are excluded
  from the denominator; short contradictory snapshots still count. Duplicates
  do not multiply votes, and simultaneous names or provider voices are ambiguous.
  Captions, roster membership and saved fingerprints do not vote.
- `speaker-mapping.json` records agreement, observed seconds, speech seconds,
  observed coverage, ambiguity and the decision for every remote speaker.
- The named variant preserves the canonical text, times, segmentation, speaker
  IDs and provider IDs. Failed re-evaluation removes a stale named variant.
- Both variants include participant metadata and the meeting title when
  available. The title is collected from explicit title controls or the already
  identified meeting's window/document/tab, saved to `meta.json`, and used as
  the Markdown heading. Generic app labels, URLs and room codes are rejected.
- Cache version 2 distinguishes diarized responses from old version-1 responses.
  Old caches require explicit cloud regeneration for completed recordings;
  offline refresh refuses to reuse them as diarization.

## Verification

- `swift build` passed with Apple Swift 6.2.3 on Apple Silicon.
- `swift test` cannot run on this host: only Command Line Tools are installed,
  and the XCTest module is absent. No full-suite pass is claimed.
- A temporary standalone assertion runner compiled and executed 38 regression
  methods from `ElevenLabsTranscriptsTests`, `SpeakerRefreshTests`,
  `ElevenLabsEngineTests`, `ElevenLabsKeychainTests`,
  `TranscriptionEngineSwitchTests` and `MeetingEvidenceTests`, linked against
  the actual debug production objects. All 38 passed. Live API and Keychain
  round-trip methods were excluded.
- Covered exactly 95%, below 95%, one failed/missing/unknown speaker, partial
  coverage, duplicate and contradictory evidence, overlapping voices, silence,
  offsets, track-scoped provider IDs, both output headers, stale variant removal,
  offline refresh, edited data protection, cache invalidation and engine switching.
- HTTP uploads were mocked; no meeting audio was sent to ElevenLabs for these
  checks. The multipart test asserts `diarize=true`.
- A separate CLI check verified that voice-memory learning rejects an ElevenLabs
  recording before audio/model access. CLI help and `git diff --check` passed.
- Live meeting-title extraction and cloud diarization accuracy still require
  validation in real calls. The installed app was not replaced by these checks.

The scanner also hoists synchronous Accessibility reads out of short-circuit
autoclosures so the existing actor confinement compiles with Swift 6.2.3;
Accessibility objects remain on the scanner actor.

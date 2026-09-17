# Persistent speaker tracking and local voice fingerprints

Validated on macOS with FluidAudio 0.15.5 on 2026-09-17.

## Room and recording lifecycle

Meet can change its room code while retaining the browser tab and accessibility
web area. The scanner now binds a meeting to that surface, updates its room code,
invalidates the old tiles, and closes the old participant interval. It keeps the
recording running and discovers the new room's participants.

UI discovery runs independently of the recording lifetime. Fresh roster state
can seed a recording, but earlier speaking observations are not replayed into
new audio. The recording's speaker source is separate from automatic-stop
policy, including manual recordings and Keep recording. Ambiguous simultaneous
calls are not combined. Disabling meeting detection clears idle tracking.

Regression tests cover same-tab breakout entry, replacement web areas, returning
to the main room, separate tabs, stale roster expiry, clearing old membership,
manual/continued recording selection, and ambiguous calls. A live Meet breakout
transition has not yet been exercised with this build.

## Local voice memory

Only verified speaking-tile spans or explicit sole-remote-speaker confirmation
can enroll voices. Sample windows exclude competing speech and overlap with one
another. At least nine clean windows are required. Enrollment rejects outliers
and requires a coherent majority before pooling disjoint groups into prototypes.

Recognition requires multiple independent pooled votes, a similarity margin
over other people, and a stronger whole-voice aggregate match. A contradictory
voice sample, current speaker label, or available participant roster rejects the
match. Fingerprint-derived labels and captions never train memory. A recording
cannot match itself; enrollment uses the source audio hash for deduplication.
Cosine similarity is an internal decision threshold, not a probability.

The private, model-versioned store retains at most 24 prototypes per person.
Atomic writes and a process lock protect updates. Corrupt/incompatible stores
remain untouched. Memory failure does not block ordinary transcription.
Previews can read memory but cannot enroll. No audio or voice fingerprint is
uploaded by this feature, and it does not record audio outside meetings.

## Verification

`swift test --disable-sandbox` with the optional local voice fixtures executed
160 tests: 151 passed, 9 opt-in tests skipped, zero failures.

The real-audio regression learned one verified participant from samples in the
first half of a recording. It then recognized held-out samples from the second
half with 13 agreeing pooled votes. A separate audio file from later in the
recording was diarized independently and matched with 8 agreeing votes. Audio
from another person's call produced no matches. Source transcripts were not
changed, and the test's fingerprint store was isolated from the user's store.

These are positive and negative regression controls, not an accuracy benchmark
across microphones, languages, all participants, or independently captured calls.

Run the optional controls with:

```sh
QUILL_TEST_VOICE_RECORDING=/path/to/verified-recording \
QUILL_TEST_HELD_OUT_VOICE=/path/to/disjoint-later-audio.wav \
QUILL_TEST_UNKNOWN_VOICE=/path/to/different-speaker.wav \
swift test --disable-sandbox --filter VoiceMemoryTests/testRealVoiceHeldOutAudio
```

The first fixture must contain enough verified UI evidence and audio for
training plus a disjoint held-out portion. The independent audio must come from
the held-out portion. Test diagnostics, when requested with
`QUILL_TEST_VOICE_DIAGNOSTIC`, stay at the supplied local path and are not fixtures
checked into the repository.

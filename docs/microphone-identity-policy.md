# Personal and shared microphone modes

PR #4 adds **Quill → Meetings → Microphone**, independently of the recording tools
in PR #3. The default is **Personal microphone**, preserving existing behavior.

- Personal mode keeps automatic owner naming, local-tile evidence,
  microphone-majority/roster-elimination inferences and editor suggestions.
- Shared mode separates microphone voices when speaker detection is enabled.
  A microphone or local tile does not establish a person's identity; source/roster
  guesses and below-threshold editor suggestions stay unconfirmed. Accepted remote
  speaking-tile evidence and manual names remain usable.
- The picker persists the existing `shared_microphone` boolean. Existing true
  values remain shared, and absent values remain personal. Failed saves retain
  the prior selection and show an error without overwriting malformed config.
- RecordingSession snapshots the choice at recording start. Transcription,
  regeneration, preview, naming and S3/HTML exports use session metadata instead
  of the current global setting. Changing Settings does not relabel old meetings.
- Shared-session legacy source guesses display as unknown while personal-session
  guesses remain visible. Original transcripts and observations are not rewritten.

## Validation — 2026-11-27

- Debug and release builds passed. Both settings options were rendered and visually checked.
- 130 targeted methods passed against production objects in
  the standalone assertion runner. Tests cover configuration round trips, legacy
  values, failed saves, recorded-mode stability, both local/Scribe paths, editor
  suggestions and consistent preview/export identity handling, plus the existing
  S3, export, linking, window layout and playback regressions.
- Full XCTest is unavailable in the installed Command Line Tools; these results
  are not a full XCTest/CI pass. Fixtures use synthetic recordings and injected
  engines/transports. No real meeting or live cloud upload was tested.

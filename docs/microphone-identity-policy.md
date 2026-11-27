# Microphone identity policy proposal

This is the separate product-policy change on top of the generic recording
features in PR #3. It is intentionally a draft for discussion.

## Behavior to decide

With a configured local name and Shared Microphone off, master may identify the
local voice from microphone-majority evidence and infer a remaining roster name.
This proposal instead leaves those voices unnamed until confirmed. A local tile
or an audio source does not identify which person in a room spoke.

- Remove microphone-majority and roster-elimination naming, including editor
  defaults from source proportions, roster counts or below-threshold evidence.
- Keep accepted remote speaking-tile evidence and explicitly confirmed names.
- Diarize both local-engine tracks when speaker detection is enabled, including
  when Shared Microphone is off. Without separation, label mic audio as local voices.
- Display previously source-inferred identities as unknown; retain manual names
  and original transcript/observation files.

This changes the single-user workflow too. A personal/shared microphone mode that
preserves automatic owner naming would be a different product decision; the base
PR deliberately preserves today's behavior while this proposal is reviewed.

## Validation

- Debug build passed.
- All 124 targeted regression methods passed in the standalone runner, including
  the S3, export, identity, layout and playback regressions from the base PR.
- Tests exercise multiple local voices, local-tile rejection, removal of roster
  guesses, local-engine diarization with Shared Microphone off, unknown display
  for legacy guesses, and preservation of manual names.
- Uses synthetic recordings and injected engines/transports. No real meeting,
  user transcript, live cloud upload or installed app is changed.
- Full XCTest remains unavailable in the installed Command Line Tools; regression
  methods run against production objects through the standalone assertion runner.

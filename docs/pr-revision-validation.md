# Generic recording features — review revision, 2026-11-27

This revision is based on master `f04a908` and retains its timestamp playback,
active-turn highlighting, pause controls and playback stop on selection change.
Speaker navigation uses stable voice/person IDs while playback retains fractional
start times and merged end times.

## Generalization

- Fresh S3 settings have automatic uploads off and empty bucket, region and
  prefix fields. Missing destination fields fail validation for manual and
  automatic uploads before transport. Existing explicitly saved settings reload
  unchanged. Examples use `transcripts/` and fictional participants.
- Repository signing instructions describe reusing each developer's certificate.
  Machine-specific instructions belong in ignored `AGENTS.local.md`.
- Automatic microphone naming, local-tile evidence, roster elimination and editor
  suggestions retain the behavior on master. Changes to that policy are separate.
- Explicit voice links and participant aliases remain available without treating
  preserved source inferences as newly confirmed identities.

## Checks

- Debug and release builds passed.
- Fresh S3 settings and the combined speaker-navigation/playback window were
  rendered with synthetic data and visually checked.
- 122 targeted regression methods passed against production objects using the
  existing standalone assertion runner. Coverage includes fresh S3 settings,
  incomplete destination rejection, retries and blocks, exports, identity links,
  existing microphone inferences, window layout, and all four playback tests.
- `swift test` cannot run on this Mac: its Command Line Tools lack XCTest.
  The standalone runner is not a full XCTest/CI pass.
- S3 tests use synthetic credentials and injected transport; no live IAM or
  production upload was tested. Meeting fixtures are temporary; installed app
  and user recordings are not replaced or edited.

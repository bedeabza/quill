# Speaker identity validation

The speaker editor supports confirmed voice links and participant aliases.
Automatic microphone naming and roster inferences retain their existing behavior;
changes to that policy are proposed separately.

- Repeated roster labels are coalesced across local/remote observations. Nicknames
  and reordered names require a confirmed alias. Equal names alone never link voices.
- Users can link voices to the same person, separate a voice, and confirm aliases.
  Edits can be cancelled. Saved changes preserve original transcripts and observations,
  and back up previous named files and identity metadata.
- Confirmed people share navigation and colours in the recording and HTML export.
  S3 Markdown includes canonical names and person/voice mappings; saved identity
  edits queue a new correction when automatic uploads are enabled.
- Voice links are bound to the original transcript's SHA-256. Regeneration invalidates
  them while preserving aliases. Stale editor state cannot save old voice links.
- Existing automatic names remain available. Preserving a source-inferred name while
  editing another voice does not silently promote that inference to user confirmation.

See [review revision validation](pr-revision-validation.md) for current checks and
limitations. All regression fixtures use fictional participants. No existing user
recordings were relabelled or modified.

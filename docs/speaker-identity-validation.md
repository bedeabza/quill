# Speaker identity validation

The speaker editor supports confirmed voice links and participant aliases.
Microphone mode is selectable in Meetings settings. Personal mode preserves
automatic naming; shared mode requires confirmation for source/roster guesses.

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
- Source-inferred names remain visible in personal recordings and appear as unknown
  in shared recordings until confirmed. Manual names and original files are preserved.

See [microphone policy validation](microphone-identity-policy.md) for checks and
limitations. All regression fixtures use fictional participants. No existing user
recordings were relabelled or modified.

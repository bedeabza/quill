# Speaker identity validation — 2026-11-17

Quill 1.6.1 (16) separates audio source, detected voice and confirmed person.

- Microphone-majority and roster-elimination naming are removed. A local meeting tile cannot establish an individual's identity. Both tracks are diarized by the local engine when speaker detection is enabled, including when Shared Microphone is off.
- Repeated roster labels are coalesced across local/remote observations. Nicknames and reordered names require a confirmed alias. Equal names alone never link voices.
- The speaker editor supports linking voices to the same person, separating a voice, and confirming participant aliases. Edits can be cancelled before saving. Saved changes retain the original transcript and observations and back up prior named files and identity metadata.
- Confirmed people share navigation and colours in the recording and HTML export. S3 Markdown includes canonical names and effective person/voice mappings alongside recorded metadata; identity edits change the upload signature and queue a new correction through the existing upload workflow.
- Voice links are bound to the SHA-256 of the original transcript. Regeneration invalidates them, while aliases survive. An editor opened against an earlier transcript cannot save stale voice links.

Validation used 109 regression methods, including synthetic mixed local/remote speech, multiple local voices, equal-name distinct people, explicit linking/unlinking, alias cycles, stale edits, cancellation, original-file preservation, export metadata, upload behaviour and window geometry. The installed Command Line Tools lack XCTest; the methods were compiled against Quill's production objects and executed with a standalone assertion runner. This is not a full `swift test` run.

The speaker editor was rendered and visually checked with a synthetic recording. No automatic alias or voice merges were applied to existing user recordings. Their manual labels remain available for explicit correction in Edit Names.

Release packaging uses the existing Quill Local Signing identity. Delivery is `.build/Quill.app`; the installed app is not replaced or restarted.

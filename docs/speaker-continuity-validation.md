# Speaker continuity validation

Validated September 14, 2026 for Quill 1.4.2, build 7.

- Added recording-local voice/name matching from sustained speaking-tile evidence.
  It requires at least 10 seconds of support across multiple turns, at least 35%
  voice coverage, 95% agreement, and no competing name with 2 seconds of support.
- Caption text never trains a voice identity. Conflicting live names veto inferred
  names, and overlapping or unobserved voices remain unresolved.
- Combined coverage across same-name UI spans without double-counting overlap.
  Zero-duration ASR words use a tiny decision window but keep their timestamps.
- Short replies can use a bounded edge of sustained tile activity. Decisions are
  marked `meeting_voice` or `meeting_tile_edge` when not direct UI evidence.
- Added `quill speakers refresh` for offline correction from the original cached
  word times and local speaker analysis. It verifies the audio checksum, preserves
  words and microphone segments, refuses manually corrected/edited transcripts,
  creates exact backups, and restores originals if an in-place write fails.

## Verification

- Full Swift suite: 107 tests, 98 passed, 9 optional checks skipped, no failures.
- Tests cover competing minority speakers, duplicate evidence, split clusters,
  caption-only evidence, delayed UI updates, zero-length words, acoustic overlap,
  changed audio, edited text, manual names, previews, backups, and track offsets.
- Replayed the completed three-remote-speaker Teams recording against recorded
  name observations and the cached Scribe transcript. Named remote words increased
  from 3,310 of 3,782 (87.5%) to 3,732 (98.7%). Unnamed remote fragments fell from
  216 to 33. No previously named word was changed to a different person.
- A control that forced three acoustic clusters performed worse than preserving
  the existing clusters and matching them to the three recorded names. That
  control was not used for the correction.
- Every transcript word was preserved and microphone segments were identical.
  The remaining 50 unnamed words are mostly short replies, overlapping transitions,
  and unusually long ASR timestamp intervals without enough recorded evidence.
- The completed recording was corrected with an exact backup and synced to its
  existing archive entry. No transcription API request or cloud cleanup ran.
- The installed application was left untouched during investigation, tests, and
  repair. The user subsequently authorized updating it at the end.

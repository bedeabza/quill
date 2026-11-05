# Recordings browser and regeneration

> This window was replaced by the Quill window; see [app-window-validation.md](app-window-validation.md).

Validated November 2, 2026.

## Behavior

- The menu's `Recordings…` entry opens a native AppKit browser with newest-first
  recording folders, search by title/folder/participant, original and named
  transcript previews, Finder access, and folder selection.
- Transcript reading and directory scans run off the main actor. Periodic
  refresh preserves selection and avoids resetting unchanged preview text.
- The selected transcription engine applies to a single regeneration job.
  ElevenLabs can reuse matching saved responses or explicitly request a fresh
  upload. Fresh requests have a visible billing/upload explanation.
- Regeneration uses the existing serial queue and works independently of the
  automatic-transcription setting. Duplicate jobs are rejected; unfinished or
  missing-audio sessions cannot be regenerated.
- Existing transcripts, attribution reports and cached responses are backed up
  before work begins. Failed jobs restore previous outputs, remove partial new
  variants and keep completed cloud responses available for retry. Audio files
  are untouched. Manual jobs do not run cleanup, voice-memory enrollment or the
  archive hook.
- Directory aliases resolve to one canonical queue identity. Regeneration,
  normal/CLI transcription, label, refresh and cleanup share the same file lock.
- Manual regeneration requires every track to succeed, including local engines,
  instead of publishing a partial replacement when one track fails.

## Verification

- `swift build` passed with Apple Swift 6.2.3.
- The host still has Command Line Tools without XCTest. The full XCTest suite
  could not run; no full-suite pass is claimed.
- A temporary standalone assertion runner linked against the actual production
  objects executed 50 regression scenarios, including the previous Scribe tests
  and 12 new library/regeneration scenarios. All passed.
- New checks cover title/participant metadata and sorting, unfinished/malformed
  sessions, readable original/named previews, backups and rollback, shared file
  locks including direct CLI transcription, canonical directory aliases,
  duplicate queue requests, failure status, cache reuse versus fresh requests,
  per-job engine selection and failure of the second local audio track.
- An offscreen native-window harness checked search, recording selection, named
  transcript switching and layouts at 1040 px and 860 px. It confirmed eight
  sample recordings, a usable transcript column and enabled regeneration for a
  completed recording. Generated previews were visually inspected.
- No user recordings were processed, no live ElevenLabs requests were made and
  no production credentials were used. The installed app was not replaced.

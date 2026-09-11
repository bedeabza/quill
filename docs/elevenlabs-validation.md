# ElevenLabs and Keychain validation

Validated September 11, 2026 on `feature/elevenlabs-transcription`.

## Behavior

- Replaced Whisper with ElevenLabs Scribe v2 in the engine menu and CLI.
- Added a masked native API-key entry dialog and Keychain-backed set/change/remove
  actions. Terminal entry uses a hidden prompt or stdin, never an API-key argument.
- Added direct cloud uploads with automatic language detection and word timestamps.
  Successful track responses are cached against their audio checksum and model.
- Kept local speaker separation and name attribution, then the existing optional
  transcript cleanup and archive sequence. Cloud failures leave a session pending.
- Removed the Whisper source, build script, and bundled helper dependency. Legacy
  Whisper selections resolve to local Parakeet until explicitly changed.
- Updated permission descriptions and documentation to describe cloud audio accurately.

## Checks

- Regression suite: 89 tests, 82 passed, 7 optional checks skipped, no failures.
- Disposable macOS Keychain test passed: absent/read/save/update/read/remove.
  Production credentials were not used by the Keychain test.
- API transport and cache tests passed, including unchanged-track reuse, changed
  audio invalidation, multipart options, rejection of redirects, offline rejection
  before credential access, and omission of secrets from the cache.
- Coordinator tests verified engine switching and that failure of the second cloud
  track does not publish a partial transcript.
- An additional opt-in live API test used the 01:50 to 03:15 excerpt of the prior
  Romanian meeting. The key was passed only in process memory. The new Swift client
  received 12 segments and preserved Romanian speech and word timestamps.
- The packaged app ran Codex cleanup on that disposable Scribe transcript.
  `postprocess.json` reported `completed`; no edits or speaker suggestions were
  needed, and the transcript hash remained unchanged. No archive hook ran.
- Release build and code-signature verification passed. Packaged executable UUID
  matches the release build. The new app contains no `whisper-cli` executable.

## Activation

Installed on September 11, 2026 after the user's explicit approval.

- Quill 1.4, build 5 is installed at `/Users/dragos/Applications/Quill.app`.
- The existing ElevenLabs key was saved in macOS Keychain through the installed
  app's stdin command. It was not placed in command arguments or JSON config.
- `transcription status` confirms `engine: elevenlabs`, the Keychain key saved,
  and `post_processing: codex`.
- The installed app successfully retrieved the Keychain credential and regenerated
  the disposable 12-segment transcript from its completed Scribe cache, without
  uploading the audio again.
- The LaunchAgent is running. Codex cleanup reports ready. Existing Accessibility
  and Zoom Screen Recording checks report no missing permissions.
- The archive hook remains `/Users/dragos/granola/sync-quill`.
- The installed bundle contains no Whisper helper.
- Computer-use inspection of the native menu timed out. The key-entry dialog's
  live visual check remains unverified; Keychain persistence and use are verified.

Previous app and configuration backup: `/Users/dragos/Library/Application Support/Quill/Backups/20260911-143817-elevenlabs`.

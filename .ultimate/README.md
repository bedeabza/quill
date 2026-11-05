Ultimate setup for Quill, the macOS meeting recorder and transcriber.

## What it adds

- `settings.json`: each worktree runs `swift package resolve` when it is created; the lander runs `swift test` on every
  landing, merges into `master` and pushes to `origin`.
- `agents/coordinator.md`: project additions for feature coordinators: how to check, README and
  `docs/<feature>-validation.md` with every feature, Quill's privacy invariants, and a closing checklist of live tests
  (recording, meeting detection, real calls) for the owner.

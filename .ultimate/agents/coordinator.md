---
name: coordinator
description: Coordinates one feature for @ultimate
addTools: []
---

Quill is a native macOS meeting recorder (Swift, SwiftPM). Work in your worktree as usual; landings merge into
`master` and push to `origin` after `swift test` passes.

- **Check:** `swift build` and `swift test` (about 30 s warm). The Parakeet regression `sh tools/test-transcription.sh`
  needs cached models; run it only when transcription itself changes.
- **Docs ship with the feature:** README.md is the spec of behaviour. Every change a user notices updates it in the
  same precise, conservative wording (what is uploaded, what is never guessed, what still needs live validation).
  A new feature adds `docs/<feature>-validation.md` like its neighbours: behaviour, then how it was validated.
- **Privacy invariants:** no silent cloud fallback or new upload without an explicit choice; speaker names only from
  evidence that passes the existing gates, never guessed; original captures and transcripts are never replaced
  without an exact backup.
- **Deploy every app change:** before `workspace submit`, run `sh tools/deploy-app.sh` from your worktree (it
  installs to `~/Applications/Quill.app` and relaunches Quill), then check the relaunched app works: open its window
  and screenshot what you changed.
- **Driving the real app shares Dragos's live desktop:** he is using the Mac while you test. Before every synthetic
  click or key, confirm Quill is frontmost and read its window's current bounds (deploys and relaunches move it), and
  aim only inside them; otherwise stop. Never send keys or clicks blind, and screenshot before acting. Any input that
  might have reached another app goes in your report: when, where, and what to check.
- **Live validation is the user's:** recording, Accessibility-based meeting detection, speaker tiles in real calls,
  Keychain prompts and notifications cannot be exercised from a worktree. Cover what you can with unit tests and
  fixtures, never start real recordings or upload audio, and end your report with a short checklist of the live checks
  Dragos should run on the packaged app (`swift build -c release && python3 tools/package-app.py`).

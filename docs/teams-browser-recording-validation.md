# Teams browser automatic recording — 2026-11-27

## Problem and change

Quill's browser detector previously looked only at `AXButton` labels, combined
button titles and descriptions into a single string, and reused call controls
from the containing browser window. This could miss Teams split buttons and
microphone toggles, shortcut-bearing labels, and Romanian controls. It could also
borrow call evidence from another document in the window.

Teams browser detection now reads title/description labels separately for button,
popup, checkbox and switch/toggle controls. It requires joined-call controls in
one HTTPS Teams document on `teams.microsoft.com`, `teams.live.com` or
`teams.cloud.microsoft`. English and Romanian labels are supported, including
case/diacritic normalization and keyboard-shortcut suffixes.

Romanian `Închideți` is ambiguous (Hang up / Close), so it requires microphone
controls plus an additional in-call action such as Show participants, and cannot
start from a prejoin page. Join/lobby states and ordinary chat/navigation/audio
settings do not authorize a new recording. Static text is not a call control.

Existing calls keep their identity when their tab moves into the background.
Incomplete reads remain unknown rather than starting a stop countdown. Explicit
end screens, return to prejoin, navigation away and confirmed tab closure retain
the existing delayed-stop behavior. An explicit end remains remembered in the
background; a fresh joined state allows rejoining to start recording again.

This fixes automatic **recording** while Quill is running with meeting detection
and Accessibility access enabled. It does not launch a closed Quill app or join
meetings on the user's behalf. The change is independent of microphone mode PR #4
and is stacked on the recording-tool base in PR #3.

## Validation and limits

- Debug and release builds passed.
- All 149 targeted regression methods passed with standalone assertions against
  production objects, including 8 Teams-specific methods and existing meeting,
  Slack, recording, identity, archive and playback regressions.
- `git diff --check` passed.
- Synthetic regressions cover English/Romanian Chrome-style controls, distinct
  title/description labels, shortcut suffixes, prejoin/lobby, false positives,
  trusted hosts, incomplete/hidden pages, and the automatic start/end/rejoin policy.
- No live Teams call was joined or recorded during development. Actual tenant/UI
  variants and the user's installed-app permissions still need a real meeting check.
- The Mac's Command Line Tools lack XCTest; targeted test methods are run against
  production objects with the existing standalone assertion runner, not full XCTest.
- No browser messages, real meeting details, recordings or credentials are included
  in the regression fixtures.

Label references: Microsoft's screen-reader meeting guides in
[English](https://support.microsoft.com/en-gb/accessibility/teams/use-a-screen-reader-to-join-a-meeting-in-microsoft-teams)
and [Romanian](https://support.microsoft.com/ro-ro/accessibility/teams/use-a-screen-reader-to-join-a-meeting-in-microsoft-teams).

# Detailed titles, speaker navigation and Claude sign-in

Implemented November 9, 2026.

## Behavior

- AI titles aim for 12–24 words and at most 180 characters, describing the topic,
  concrete context, decisions or unresolved next steps. Validation accepts up to
  200 characters/32 words without links, headings or control characters. Existing
  short-title caches are upgraded once when browsed; generation version 2 then
  reuses content-matched results. Transcript excerpts remain bounded and untrusted.
- Local fallback prefers an informative original content sentence, ranked using
  repeated topic words; otherwise it offers up to five keywords/phrases. The UI
  identifies local fallback and failed/unavailable AI. Long titles wrap fully in
  the meeting header and occupy up to three lines in recording rows.
- Speaker names can be typed freely or selected from participants, including new
  names absent from the roster. Drafts update the voice header and all its turns
  immediately. Apply writes the existing manual named variant under its lock,
  with backups; Cancel restores the saved display. The original remains intact.
  Invalid nonempty names are refused rather than silently saved as Unknown.
- Every transcript turn retains its stable voice ID separately from its display
  name. Consecutive different voices stay distinct even with the same name. Each
  voice's navigation cursor advances through its own turns and wraps to the first;
  changing recordings resets cursors. Colour and navigation survive renaming.
- Speaker navigation and name controls sit outside the transcript scroll view.
  Many voices can be reached horizontally; the editor has bounded internal
  overflow. Hide Name Editor preserves drafts and gives the transcript more space.
- Transcription settings and failed Claude titles offer Sign In to Claude.
  An owner-only, temporary command file invokes the installed helper's official
  `auth login --claudeai` flow in Terminal, opening the browser without requiring
  the user to type a command. Its helper path is shell-quoted. The script removes
  itself after the helper exits; launch failure also removes it.
- Verify Connection performs a restricted synthetic structured-output request,
  not just an auth-status check: saved but expired credentials do not count as a
  successful connection. It sends no meeting text/audio. The provider setting is
  preserved and title regeneration remains an explicit action after sign-in.
  Quill does not collect passwords, implement OAuth or copy helper tokens.

## Validation

- Debug/release builds completed. The replacement app is signed with the existing
  Quill Local Signing certificate; its designated requirement retains the same
  certificate leaf. Packaged/release binary identity and CLI help were checked.
- 45 targeted regression methods ran against production objects using a
  standalone assertion runner. They cover the existing title/library/regeneration
  and naming behavior plus detailed-title cache upgrades, fallback context,
  separate same-name voices, per-voice navigation/wrap, immediate name previews,
  cancellation, persistence, invalid names, polling, editor collapse/reopen,
  missing helpers, login-launch refusal/cleanup, synthetic verification outcomes,
  and executable-path quoting through a fake login helper.
- The full-window regression includes a 100-turn transcript and a long title at
  1100×720 and 900×600, checks every sidebar row stays inside the window, keeps a
  usable transcript viewport and switches through all sections.
- `swift test` cannot execute here: this Mac has Command Line Tools without the
  XCTest module. The standalone checks are not a full-suite or CI pass claim.
- A synthetic 80-turn UI fixture verified actual transcript scrolling after
  navigation requests, immediate renamed header/text rendering, and layouts at
  1100×720 and 860×560. The sign-in sheet was rendered and inspected. No real
  recording, login flow or model request was used by these UI fixtures.
- The synthetic connection diagnostic handles an expired helper credential
  (HTTP 401) without sending meeting content. A successful live title requires
  completing browser authentication and verifying the connection.
- No production recording/transcript/title was changed by these checks, and the
  installed app was not replaced or restarted.

The login flow follows the [official Claude Code authentication documentation](https://code.claude.com/docs/en/authentication)
and the installed helper's `auth login --help`. A title is still model output;
its desired length does not justify inventing content for a very short meeting.

## Full-window layout correction

The first package's standalone recordings-pane checks missed its interaction
with NavigationSplitView. ScrollViewReader contributed the complete transcript's
ideal height to the split view, giving sidebar columns several thousand points
of height and clipping their menu rows outside the visible window. Its viewport
and enclosing detail now explicitly accept a zero minimum and the available
height. Only speaker navigation/editing stays fixed; meeting title/context and
the transcript scroll together, so long titles cannot consume the whole detail
at the minimum window size. A capture of the complete synthetic window verified
the native sidebar labels, in addition to the geometry and section-click checks.

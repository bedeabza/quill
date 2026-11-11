# Zoom screen sharing keeps the meeting

## Behaviour

- Desktop Zoom hides its meeting window while you share your screen. For an
  already detected Zoom meeting whose window is no longer listed, `MeetingScanner`
  now reads, in order:
  1. another Zoom window with call controls: the meeting is **present**; if
     that window is not already a known meeting's window, it becomes this
     meeting's window (same meeting ID);
  2. a Zoom share window: a title starting `zoom share` (share toolbar or
     status bar), a `Stop Share`, `Stop Sharing`, `Pause Share` or
     `Resume Share` button, or participant video tiles labelled with their
     audio state (the floating video panel): **present**. The home window's
     `Share screen` button is not a share in progress;
  3. Zoom running audio input or output (Core Audio
     `kAudioProcessPropertyIsRunning` for its process or a helper whose bundle
     ID starts with Zoom's; no audio is read): **unknown**. Recording continues
     with "Meeting status unavailable; recording continues";
  4. otherwise **ended**, as before: the 30-second countdown starts.
- None of these start a recording. Only a window with call controls does, as
  before.
- When a call window returns after its window was hidden or replaced, and the
  meeting was not read as ended, it rebinds to the existing meeting ID, so the
  recording keeps one meeting ID and speaker tracking resumes.
- A meeting stopped automatically (its countdown expired) is no longer marked
  dismissed. If it reappears, recording starts again on the next 2-second
  poll, without needing another "ended" read first. A manual stop still
  suppresses restart until the meeting ends.
- `quill meetings --windows` lists each desktop meeting app's windows: title,
  button labels, video tile count, `call_controls`, `zoom_share` and
  `audio_running`.

## Incident

2026-11-11, one Zoom call (Dragos, Kristi Hupfeld, Marius Sandu, steven)
became three recordings, and two stretches of about 2.5 minutes were not
recorded:

| Recording | Meeting ID | Recorded (UTC) | Last roster read |
|---|---|---|---|
| 2026.11.11-1401 | 19284:12 | 19:01:19–19:07:33 | 19:06:57 |
| 2026.11.11-1409 | 19284:13 | 19:09:35–19:17:09 | 19:16:35 |
| 2026.11.11-1419 | 19284:1 | 19:19:23–19:26:28 | 19:25:54 |

- Each recording stopped 34–36 s after its last roster read: the meeting read
  as ended (closed window) for 30 s, then stopped.
- Dragos (speaker `meeting_2`, local microphone) says "Can I share my screen?"
  5:40 into 1401, and "give me a second… Like this, right?" at the end of 1409.
  1419 ends with goodbyes: a real end.
- Quill's screen-capture permission check (`TCCAccessRequest`, unified log)
  runs every 2 s only while the known Zoom meeting window lists video tiles. It
  stopped at 14:06:47 and 14:16:35 local and did not run again until the next
  recording: the meeting window was absent for the whole share, about 2 m 36 s
  and 2 m 46 s. Recording resumed when the window returned. The "2-minute
  restart" was the share's duration, not a slow restart. The third recording
  started in a new Quill process (pid 27979, launched 14:17:31 by a deploy),
  which also saw no meeting window until 14:19:23.
- `audioaccessoryd`'s 3-second audio snapshots show Zoom (`us.zoom.xos`)
  holding the Bluetooth audio route throughout both gaps
  (14:07:34–14:09:37 and 14:17:10–14:19:25, Zoom alone) and releasing it at
  14:25:58, within 4 s of the meeting's end.
- Sharing did not change the default input: the log has `default input device
  changed` only at 13:59:01 (before the call) and 14:26:22, after the call
  ended, when the headset route moved from Zoom to Quill alone (the 0.28 s
  microphone gap in 1419).
- Quill's own stderr goes to `/dev/null` when launched from the app bundle, so
  the scanner's per-window reads during the share were not recorded. Which
  Zoom windows were listed while sharing is not known yet.

## Validation

- `swift test`: 248 tests, 11 skipped, 0 failures. New:
  - `ZoomMeetingEvidenceTests.testShareWindowsAreRecognizedButHomeShareButtonIsNot`.
  - `ZoomMeetingEvidenceTests.testSharingNeverEndsAnEstablishedZoomMeeting`:
    share window → present, audio only → unknown, neither → ended; a policy
    fed 170 s of unknown reads never stops.
  - `MeetingPolicyTests.testAutomaticallyStoppedMeetingRestartsAtOnceWhenItReturns`
    fails on the previous policy (the meeting stayed dismissed) and passes now.
- Proved once with a throwaway test during a live Google Meet in Brave:
  `AppAudioActivity.isRunning` is true for Brave with its bundle ID (the audio
  runs in `com.brave.Browser.helper`), false for the same pid without it, and
  false for an idle Zoom.
- `quill meetings --windows` with Zoom idle and Teams open lists Teams' chat
  window with `call_controls: false`, `audio_running: false`.

## Live checks (Dragos)

Zoom's share windows cannot be produced from a worktree. In the next Zoom
call where someone shares:

1. Before sharing, in Terminal:
   `~/Applications/Quill.app/Contents/MacOS/quill meetings --watch --windows > /tmp/zoom-share.jsonl`
2. Share your screen for 30 s or more, stop; if someone else shares, leave it
   running through that too. Then press Ctrl-C.
3. Quill's recording continues through the share as one recording, and the
   menu status never shows a countdown.
4. Send `/tmp/zoom-share.jsonl` back: the `windows` rows show which share
   windows Zoom listed and whether `zoom_share` or `audio_running` recognised
   them. It contains Zoom's window titles and button labels, which may include
   names.
5. After leaving the call, recording stops about 30 s later. If it keeps
   recording with "Meeting status unavailable", Zoom kept its audio running
   after the call (the capture's `audio_running` shows it): stop manually and
   send the capture.

## Known limits

- While a Zoom meeting whose window is gone reads uncertain because Zoom still
  runs audio (for example a Zoom Phone call right after), it is not pruned; the
  next Zoom meeting window adopts its ID and an ongoing recording continues
  into it. Before this change a call window appearing during the countdown
  already kept the recording going.
- The share-window labels are unconfirmed; once a live capture shows the real
  ones, the patterns should be narrowed to them. They can only delay a stop for
  as long as a share window stays open.

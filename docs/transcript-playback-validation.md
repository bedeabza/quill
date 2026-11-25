# Playing a transcript from a turn

Validated November 25, 2026.

## Behavior

- In the Recordings detail pane, hovering a speaker turn shows a play symbol in
  the margin beside its timestamp and tints the timestamp; the symbol and the
  timestamp are one button. Clicking it plays the recording from the turn's
  first segment start and keeps playing through the following turns until it is
  paused or the recording ends.
- The turn being spoken has a subtle accent background, an accent timestamp and
  a speaker symbol. Of the turns covering the playback time, the one that
  started last is highlighted (an interjection over a longer turn); in a pause
  between turns the last turn stays highlighted; before the first turn none is.
  Turns use the segment times from `transcript.json` (or the named copy):
  consecutive segments of one speaker merge into a turn from the first start to
  the last end.
- When the highlighted turn is not mostly visible, the transcript scrolls it to
  about a fifth from the top. Scrolling by hand stops this following; playing a
  turn or the player's **Show Current** button (list symbol, shown only while
  not following) turns it back on.
- While a recording is loaded for playback, a 30-point player bar under the
  transcript, level with the list's folder footer, shows play/pause, the
  current time, a scrubber, the duration, **Show Current** when needed, and a
  close button. Space plays and pauses once a turn was played (the transcript
  takes focus); it does not reach the search field or the speaker pickers.
- Selecting another recording, leaving Recordings or closing the window stops
  playback and releases the audio files. Hiding Quill does not stop it.
- Audio, on the transcript's meeting clock: `meeting-audio.wav` when present
  (offset 0, the aligned mix ElevenLabs transcribed); otherwise every track in
  `meta.json` (`mic.caf`, `system.caf`) that is readable, each inserted into an
  `AVMutableComposition` at its `start_offset_ms`. That is the shift
  `TranscriptionCoordinator` adds to each track's segments and the position
  `MeetingAudio` gives each track's first sample. Without `meta.json` or any
  readable track, the turns have no play button and the transcript header says
  **No audio to play** with the reason as its tooltip.
- Playback opens audio files for reading only and writes nothing to the
  recording folder. `tools/deploy-app.sh` now treats only `.caf` files open for
  writing as a recording in progress, so a loaded player does not block deploys.

## Verification

- `swift test`: 252 tests, 11 skipped, 0 failures. New `TranscriptPlaybackTests`:
  the active turn through a pause, an interjection inside a longer turn, before
  the first and after the last turn; source selection (no `meta.json`, missing
  files, one track, both tracks with a 468 ms mic offset, then
  `meeting-audio.wav` preferred); a composition of a silent `system.caf` at 0 s
  and a 1 s tone `mic.caf` at 0.5 s rendered through `AVAssetReader`, first sound
  at 0.50 s and length 1.50 s; and the model playing from a turn, highlighting
  it at once, and stopping when another recording is selected or the section
  closes.
- Timestamps against real recordings (throwaway probe, deleted): for three
  segments each of a Parakeet recording (`mic.caf` + `system.caf`, mic offset
  125 ms), an older ElevenLabs recording without a mix (mic offset 735 ms) and a
  recent one with `meeting-audio.wav`, the composition was rendered from the
  segment's start to its end and transcribed with Parakeet. Every non-empty
  result was that segment's words, for example "So I would say pipeline in
  total, but I don't think that's necessarily a fault of the org itself." heard
  as "So I would say pipeline in total, but I don't think that's necessarily a
  a fault of the org itself." Three short clips returned no text. For the
  recording with a mix, the tracks composition correlated best with
  `meeting-audio.wav` at a 0.0 ms lag.
- Packaged app (`sh tools/deploy-app.sh`), output muted during the test and
  restored after: hovering a turn showed the play symbol; clicking 00:02:35 of a
  recording with `meeting-audio.wav` started playback there with that turn
  highlighted, and four seconds later the highlight had moved to the 00:02:39
  turn. Space paused and resumed. Playing on past the visible turns scrolled the
  spoken turn into view; scrolling up by hand stopped the following and showed
  **Show Current**. Selecting another recording, and closing the window, removed
  the player, closed the audio file (`lsof`) and stopped Quill's audio output
  (Core Audio process `IsRunningOutput`).

## Needs live validation

- Listening at normal volume: the played words match the highlighted turn, on a
  recording with `meeting-audio.wav` and on an older one with separate tracks.
- How the separate tracks sound for a call taken without headphones (the mic
  also captured the call).
- The scrubber dragged with a trackpad, and Space after clicking into the
  transcript text.

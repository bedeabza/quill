# Microphone continuity across input changes

## Behaviour

- `MicRecorder` records the default input. When the engine reports a
  configuration change it did not survive (`AVAudioEngineConfigurationChange`
  with the engine stopped or the input format changed), or the default input
  device changes, capture restarts on the current default input after 0.3 s
  (one restart per burst of notifications, at most 10 per minute). The restart
  uses the configured `mic_voice_processing`; the first-second liveness check
  runs again and can still fall back to raw capture.
- The same `mic.caf` continues. `MicTrack` resamples a new input to the track's
  rate (set by the first input) and writes the time between the last buffer
  and the first new one as silence, measured on the host clock, so the track
  stays aligned with `system.caf`. The liveness fallback no longer deletes the
  file: the silent second stays in the track at its real time.
- `meta.json` gets `microphone_gaps`: every stretch the microphone missed, in
  seconds on the transcript clock (`[]` when none). A capture that could not
  restart leaves a trailing gap up to the stop; a microphone that never
  delivered audio is one gap over the whole recording.
- Each transcription writes the gaps to `transcribe.log`
  (`microphone not recorded (meeting clock): 387.5–389.1 s`).
- The Recordings detail shows one secondary line under the participants, with
  a `mic.slash` symbol, for gaps of at least 5 s: "Microphone stopped at 6:27.
  Your voice after that wasn’t recorded." for an early stop, otherwise
  "Microphone not recorded 20:00–21:00, …". Recordings without
  `microphone_gaps` (made before this change) only show an early stop, derived
  from the length of `mic.caf` plus its start offset against `duration_seconds`.
- Nothing about transcription, uploads, the combined meeting recording, cached
  responses or speaker naming changes.

## Incident

2026.11.11-1136 (Teams with Emil Muthu, 40 min): AirPods connected 6:27 into
the recording. The unified log shows `default input device changed`, then
`AUHAL: Device 718 died!`, and the engine stopped; `mic.caf` ends at 387.2 s
while `system.caf` runs 2383.5 s. Teams lit Dragos's tile for about 1,129 s
after that, none of it recorded anywhere. Scribe heard one voice, correctly
named Emil Muthu.

Two older recordings have the same symptom (`2026.11.02-0915`: 6 s of mic in
3,560 s; `2026.10.22-1129`: 313 s in 2,130 s). The unified log no longer holds
entries for those dates, so their cause could not be confirmed.

## Validation

- `swift test`: 245 tests, 11 skipped, 0 failures. `MicTrackTests`:
  - 1 s at 48 kHz, a restart, then 1 s at 24 kHz starting 2.5 s later: one
    file of 4.5 s at 48 kHz (less the resampler's 20 ms filter latency), the gap
    1.0–3.5 s recorded and silent, the resampled tone at its original level.
  - A stop 0.3 s after the last buffer is no gap; 28 s later is a trailing gap.
  - `microphone_gaps` is read as stored and never re-derived when present
    (even empty); an older recording with a short `mic.caf` yields its early
    stop; the notice and log texts.
- Deployed with `sh tools/deploy-app.sh` and opened the Quill window: the
  2026.11.11-1136 detail shows "Microphone stopped at 6:27. Your voice after
  that wasn’t recorded."; a recording with a complete microphone track shows
  no line.

## Live checks (Dragos)

Real device switches cannot be exercised from a worktree:

1. Start a test recording on the laptop microphone, connect AirPods, speak,
   disconnect them, speak, stop.
2. `afinfo mic.caf` and `afinfo system.caf`: durations within about a second.
3. `meta.json` `microphone_gaps`: short gaps (under a second or two) at the two
   switches; no trailing gap.
4. Play `mic.caf` around the switches: your voice on both sides, at the right
   time against `system.caf`.
5. Repeat with `mic_voice_processing` on, and once choosing another input in
   System Settings › Sound mid-recording.

---
title: "Microphone track ends when the input device changes"
date: 2026-11-11
status: done
affects: "microphone recording, speaker attribution"
---

## Context

2026.11.11-1136, a 40-minute Teams call with Emil Muthu, was transcribed by
ElevenLabs as one voice, named Emil Muthu. Dragos spoke a lot.

## Evidence

- `mic.caf` is 387.2 s; `system.caf` is 2383.5 s.
- The unified log at 11:42:50.7 local (387 s into the recording) shows AirPods
  connecting, then in Quill: `HAL notification: default input device changed`,
  `AUHAL: Device 718 died! Looking for usable device...`, a switch to the
  AirPods' 24 kHz input, and the IO stopping. Nothing restarted it.
- Teams lit Dragos's tile for about 1,129 s after that. During those stretches
  `system.caf` sits at a median of −83 dBFS: his voice is in no file.
- The 2,500× system-to-microphone energy ratio in `meeting-audio.json` is
  mostly the missing track: over the first 387 s the ratio is 30× (about
  15 dB, normal playback level). Echo cancellation lowered his speech by only
  2.1 dB. Of his 6.7 s of in-call speech before the stop, Scribe transcribed
  4.8 s, merged into the one voice.
- Same symptom in `2026.11.02-0915` (6 s of 3,560 s) and `2026.10.22-1129`
  (313 s of 2,130 s); the log no longer covers those dates.

## Root cause

`AVAudioEngine` stops when its input device configuration changes and posts
`AVAudioEngineConfigurationChange`. `MicRecorder` did not observe it, nor
default-input changes, so the track ended silently while `system.caf`
continued.

## Fix

`MicRecorder` restarts capture on the current default input after either
signal and keeps writing the same file through `MicTrack`, which resamples and
writes the switch-over as silence on the host clock. Gaps are recorded in
`meta.json` (`microphone_gaps`), logged in `transcribe.log` and shown in the
Recordings detail. See `docs/microphone-continuity-validation.md`.

Rejected: multichannel upload (the missing audio was never captured; it also
drops remote diarization and likely doubles billing) and loudness
normalization before the mix (unproven; it would change the preparation
version for every recording).

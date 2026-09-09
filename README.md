# quill

A minimal, fully local macOS meeting recorder + transcriber. One menu-bar
click records your mic and all system audio as two separate tracks; when you
stop, quill transcribes both on-device and writes a speaker-tagged transcript.
Nothing ever leaves the machine.

Named for the feather. Sibling of [parrot](https://github.com/digimata/parrot), now packaged as a native macOS
menu-bar app with its own identity, icon, and notification permissions.

## Source

Use [bedeabza/quill](https://github.com/bedeabza/quill) for builds and updates.
This fork includes automatic meeting recording and start/stop banners. The
original [digimata/quill](https://github.com/digimata/quill) is retained as the
upstream project.

## Install

```sh
git clone https://github.com/bedeabza/quill.git
cd quill
swift build -c release
python3 tools/package-app.py
```

Move `.build/Quill.app` to `~/Applications` using Finder. Quit an older copy
before replacing it. Quill keeps recordings and configuration outside the app,
so replacing the app preserves both.

To keep the terminal command and start Quill at login:

```sh
python3 tools/install-cli.py
"$HOME/Applications/Quill.app/Contents/MacOS/quill" install --launch-at-login
```

Open Quill once and allow Notifications and Microphone when macOS asks. Enable
**Quill** under Privacy & Security > Accessibility for meeting detection. System
audio permission is requested on the first recording. Only one recording app
instance can run, whether opened from Finder, the terminal, or the login service.

Native notification diagnostics:

```sh
quill notifications         # report this app's notification authorization
quill notifications --test  # send a test and confirm Notification Center delivery
```

The app uses Apple's UserNotifications framework directly. Denial and delivery
failures are reported in the log; no AppleScript bridge or separate helper is
used. Desktop banners remain subject to macOS notification and Focus settings.
The terminal launcher executes the app binary by its full path, preserving
macOS bundle identity; a plain symlink does not reliably preserve that identity.

**Requires:** macOS 15+ (Core Audio process taps for system audio — no
virtual device, no kernel extension). Apple Silicon recommended for
transcription speed.

## How to use

1. **Run it** (`quill` in a terminal, or the LaunchAgent).
2. **Click the feather in the menu bar → Start recording.** First use prompts
   for microphone and System Audio Recording permissions. While recording, the
   icon turns red with a running elapsed counter, and macOS shows the purple
   recording indicator.
3. **Click → Stop recording** when the meeting ends. Transcription starts
   automatically (the menu shows progress); a notification fires when the
   transcript is ready.

Each session lands in `~/Recordings/<yyyy.MM.dd-HHmm>/`:

| File | Contents |
|---|---|
| `mic.caf` | your side (default input device, AAC) |
| `system.caf` | everything the Mac played — the other side of the call (AAC) |
| `meta.json` | start/end timestamps, duration, per-track start offsets |
| `transcript.json` | canonical transcript — engine provenance + timed, speaker-tagged segments |
| `transcript.md` | the same transcript rendered for reading |
| `transcribe.log` | transcription progress/errors for this session |

Two tracks keep your microphone separate from remote audio. Quill now runs
speaker diarization on the remote track and aligns speakers to individual
word timestamps. CAF needs no finalization pass, so audio already written
remains readable if the process exits unexpectedly.

## Speaker names

Speaker separation runs automatically after recording, entirely on-device,
using FluidAudio's offline Pyannote/WeSpeaker/VBx pipeline. Unknown voices
receive stable IDs within that transcript and readable labels such as
`Speaker 1`. Ambiguous overlapping speech remains `Unknown speaker`.

For Google Meet, Quill reads each visible speaker tile's name and speaking
indicator through macOS Accessibility. It caches the tile controls during its
regular meeting scan, then reads their state four times per second while
recording. This works independently of the spoken language and does not
require Meet captions, saved transcripts, or a browser extension.

Only observed speaking intervals receive names. Multiple active remote tiles,
missing observations, very short activity, and unrecognized markup remain
unattributed. Names never propagate to unrelated turns in an acoustic cluster.
The local tile is excluded from remote naming, and changing tile names invalidate
the cached association until the next scan. Minimized meeting windows cannot
provide tile evidence. The name and activity structure was verified in Brave;
other browsers need live validation. Teams and Zoom currently contribute only
explicit accessible speaking labels when exposed.

Captions, when already enabled, remain an optional source of additional evidence.
A unique five-word phrase can match a caption to the local transcript, but a
wrong caption language may prevent that match. Quill no longer enables captions
by default. Set `auto_meeting_captions` to `true` to restore that behavior.

Your microphone uses the configured local name, captured in session metadata
at recording time. For several people sharing your microphone, set
`shared_microphone` to `true` to separate those voices too.

Optional configuration in `~/.config/quill/config.json`:

```json
{
  "speaker_detection": true,
  "auto_meeting_captions": false,
  "local_speaker_name": "Your name",
  "shared_microphone": false
}
```

Preview a completed recording without changing it or invoking archive hooks:

```sh
quill transcribe /path/to/recording --output /tmp/speaker-preview
quill meetings --speakers
quill meetings --speaker-boxes
```

Use `--offline` to require cached models, `--no-speakers` to skip separation,
or `--remote-speakers 4` to supply a known count. `--force` replaces an
existing transcript and regenerates speaker IDs and names. Automatic counts
are estimates; similar voices, short interjections, echo, and overlapping
speech can still merge or split speakers.

Correct a separated speaker:

```sh
quill speakers label /path/to/recording --speaker system_1 --name "Alice"
```

Corrections make an exact JSON backup and update every matching turn.
A known one-to-one recording can be corrected with `--sole-remote-speaker`
instead of `--speaker`, explicitly confirming that all remote speech is from
that person. This includes otherwise unknown remote segments.
A rerun of diarization does not reuse manual names against potentially changed
speaker IDs. Run your archive sync separately to publish a correction.
Voice recognition across meetings is deferred: the independent-utterance
experiment did not reliably match the same voices, so this release stores no
persistent voice profiles.

`speaker-observations.jsonl` contains captured caption/activity evidence;
`speaker-analysis.json` stores turns and name evidence. Transcript schema
v2 preserves `speaker`, `source`, `speaker_name`, and `attribution` separately.
The matching Granola importer preserves those names while retaining legacy
transcript rendering. A diarization failure is logged and marked in the
transcript's `speaker_detection` field while the text is retained.

Tests cover word-boundary alignment, delayed/stale/self captions, conflicting
names, and offline one-, two-, three-, and four-voice audio
fixtures. The audio fixtures come from the public
[meeting-transcriber test suite](https://github.com/pasrom/meeting-transcriber/tree/main/app/MeetingTranscriber/Tests/Fixtures);
the four-voice sample is an AMI ES2004a excerpt (CC BY 4.0).
`tools/download-diarizer.py` can prepare the approximately 21 MB model cache.

## Transcription

Built in, on-device, automatic. The default engine is **Parakeet TDT 0.6B v3**
via [FluidAudio](https://github.com/FluidInference/FluidAudio)'s Core ML port.
It automatically detects and transcribes **English and Romanian** in their
original language, without changing settings between meetings. The
[model supports 25 European languages](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3).
Audio stays on your Mac.

The multilingual models download once on first transcription; `quill doctor`
checks the v3 cache specifically. Upgrading from the English-only v2 engine
requires a new model download, even if the old models are cached. Existing
`"engine": "parakeet"` configurations automatically use v3. Completed
transcripts are left as they are; this change applies to pending and future
transcriptions.

Each track is transcribed separately, shifted by its start offset so both
share one clock, and merged by timestamp. Jobs run in a serial queue — you can
start a new recording while the last one transcribes. Unfinished jobs resume
on next launch (the filesystem is the queue: a session with `meta.json` but no
`transcript.json` is pending). Failures append to the session's
`transcribe.log` and never block later jobs.

To run the on-device English/Romanian regression after the v3 models are
cached, use `sh tools/test-transcription.sh`. It synthesizes disposable speech
with macOS's Samantha and Ioana voices and checks English, Romanian (including
diacritics), and switching back to English on the same engine. The regular
`swift test` suite skips this model-dependent test.

The engine sits behind a small protocol; a Whisper engine (WhisperKit
large-v3-turbo) is planned as the fallback / re-transcription option.

## Config

Optional, at `~/.config/quill/config.json`:

```json
{
  "recordings_dir": "~/Recordings",
  "transcription": { "enabled": true, "engine": "parakeet" },
  "on_stop": "my-hook"
}
```

- `recordings_dir` — where sessions land. Resolution order: `--out` flag >
  config > `~/Recordings`.
- `transcription.enabled` — set `false` to just record.
- `mic_voice_processing` — Apple's echo cancellation on the mic (default off).
  Set `true` when recording meetings through the speakers, so playback doesn't
  bleed into the mic track and get transcribed twice as "me". The trade: while
  the voice unit is live, macOS ducks other playback slightly (`.min` ducking
  is configured, but it can't be zeroed). On headphones there's no echo to
  cancel, so raw capture is the better default.
- `on_stop` — shell command spawned with the session directory as its
  argument, **after the transcript is written** (or right after recording if
  transcription is disabled). Wire it to whatever comes next: summarization,
  filing, indexing.

## Meeting detection

With **Automatic meeting recording** enabled in the menu, Quill starts detected
meetings automatically and stops 30 seconds after the associated meeting tab or
call window closes. Native macOS notifications announce recording start and stop,
without asking for confirmation. Their appearance and visibility follow macOS
notification preferences and Focus settings. Use **Allow meeting detection** to
grant macOS Accessibility permission. Turning the toggle off stops an automatically started
recording; manually started recordings remain under manual control. The menu
also offers **Keep recording after meeting ends**. Manually stopping a recording
suppresses automatic restart for that meeting until it ends or the toggle is
turned off and back on.

Detection uses macOS Accessibility, without browser extensions. Brave, Chrome,
Edge, Safari, Firefox, Arc, and other browsers registered to handle web URLs are
inspected for exposed meeting tabs. Desktop Teams and Zoom are inspected for
call controls and their meeting windows. Google Meet, web Teams, and web Zoom
pages can be recognized when the browser exposes the relevant meeting URL.
Background tab labels maintain a previously identified meeting, but cannot
start recording by themselves.

Browser/app versions and accessible labels vary. Closed tabs and windows are
end signals; recognized English-language end screens are also supported. A
hidden control, mute, silence, switching tabs, or a failed Accessibility read
does not authorize stopping. If a browser hides its tab information, or an app
keeps the window open without an identifiable end screen, Quill continues
recording and reports that meeting status is unavailable. Manual stopping stays
available. Calls in other UI languages need matching accessible labels.

The feature is on by default and can be disabled in the menu or with
`"meeting_detection": false` in the existing configuration file. Recordings,
transcription, and `on_stop` archive hooks retain their normal behavior.

For read-only diagnostics, use `quill meetings` or `quill meetings --watch`.
The output lists app/service and detection state, without meeting content.

## CLI

```sh
quill                        # run the menu-bar daemon (^C to quit)
quill run --out <dir>        # custom recordings root (default ~/Recordings)
quill doctor                 # check permissions, recordings folder, models
quill install --launch-at-login
quill install --uninstall
```

## Stack

- **Swift** — single SPM executable target
- **Core Audio process tap** (`AudioHardwareCreateProcessTap`, macOS 14.2+) —
  system audio capture via a private aggregate device
- **AVAudioEngine** — mic capture
- **AVAudioFile** — streaming AAC encode into CAF
- **FluidAudio / Parakeet** — on-device Core ML transcription
- **NSStatusItem** — the whole UI

## Gotchas

- A global tap records *everything* the Mac plays — notification dings,
  music, all of it. Don't play Spotify during meetings (or ask for a
  per-process picker if it bothers you).
- If recordings come out silent, check System Settings → Privacy & Security →
  Screen & System Audio Recording.
- Parakeet v2 is English-only. Other languages will come with the Whisper
  engine.
- The app bundle provides Quill's identity and permission descriptions. Local
  ad-hoc-signed rebuilds may require refreshing Quill's Accessibility entry.

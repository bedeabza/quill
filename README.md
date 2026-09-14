# quill

A minimal macOS meeting recorder + transcriber. One menu-bar
click records your mic and all system audio as two separate tracks; when you
stop, Quill transcribes both and writes a speaker-tagged transcript.
Choose local Parakeet v3 or cloud transcription with ElevenLabs Scribe v2.
Parakeet remains the default; selecting ElevenLabs uploads audio to its API.
Optional transcript cleanup uses your signed-in Codex or Claude Code CLI and
sends transcript text to its cloud provider.

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

## Optional transcript cleanup

The menu's **Transcript cleanup (cloud)** submenu offers **Off** (the default),
**Automatic**, **Codex (ChatGPT account)**, and **Claude Code**. It processes new
completed recordings before the archive hook runs. The existing transcription
and archive flow continues when cleanup is off, no compatible signed-in CLI is
available, a provider fails, output fails validation, or the run times out.

This uses the installed `codex` or `claude` command-line harness and its saved
sign-in. Installing only the ChatGPT or Claude desktop chat app is insufficient.
Automatic prefers a compatible signed-in harness associated with an open app;
Codex wins a tie. Otherwise it checks Codex, then Claude Code. An explicit choice
never falls back to the other provider, and a failed model request is not resent
to another provider. Quill never installs a harness or prompts you to sign in.

Enabling this option sends transcript text, speaker labels, and any configured
glossary to the selected harness's cloud provider and uses that account's limits.
It is not local model inference. New runs use the setting in effect after local
transcription finishes; changing the setting does not retract a request already
sent. The CLI's normal default model is used. No additional API key is required.

Corrections are constrained to small text edits. Segment boundaries, timestamps,
IDs, existing names, numeric values, and explicit English/Romanian negations are
preserved. A failed validation rejects the whole response. These checks reduce
unwanted rewriting but cannot prove every correction is accurate. Speaker-name
suggestions require cited transcript evidence and are saved for review only;
they never automatically replace unknown speaker labels.

A successful edit keeps exact originals under `postprocess-backup-<id>/`, updates
`transcript.json` and `transcript.md`, and records edits, speaker suggestions,
provider, and input/output hashes in `postprocess.json`. Repeating a successful
run on the same transcript skips it. The one-off command does not run the archive
hook. Existing recordings are not automatically submitted when cleanup is enabled.

```sh
quill postprocess status
quill postprocess configure --mode auto
quill postprocess configure --mode off
quill postprocess run /path/to/completed/recording --harness claude
```

For a domain glossary or a different timeout, add this to the existing config:

```json
{
  "post_processing": {
    "mode": "off",
    "timeout_seconds": 120,
    "glossary": ["YAROOMS", "Yarvis"]
  }
}
```

Timeouts are bounded to 10–600 seconds per model run. Inputs over 300 KB or 5,000
segments are skipped. Raw transcription, including `quill transcribe --offline`,
never invokes a cloud harness. Codex requires `exec --ignore-user-config`,
`--ephemeral`, and structured output support; Claude Code requires `--safe-mode`
and structured output support. Unsupported older CLIs are skipped. Background
harness runs use a private temporary directory, restrict tools and customizations,
disable session persistence, and terminate the subprocess group on timeout.

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

Recorded speaking tiles provide direct name evidence. Quill can also retain a
name through missing tile samples when that recording's acoustic voice has at
least 10 seconds of consistent UI evidence across multiple turns, sufficient
coverage, and no sustained competing name. Split acoustic clusters may share
the same verified name. Caption text alone never establishes a voice identity.
Conflicting evidence and ambiguous overlapping voices remain unresolved.
Short replies can use a bounded edge of a sustained speaking indicator to
account for UI delay. Words with uncertain evidence keep an anonymous label.
The local tile is excluded from remote naming, and changing tile names invalidate
the cached association until the next scan. Minimized meeting windows cannot
provide tile evidence. The Meet name and activity structure was verified in
Brave; other browsers need live validation.

Teams desktop uses its accessible participant names and speaking-frame state.
This was checked in a two-person call with captions off. Unknown layouts and
explicitly pinned tiles do not contribute names.

Zoom desktop exposes participant names through Accessibility. Quill also needs
Screen Recording permission to read the green/yellow active-speaker borders.
Only the identified Zoom meeting window is captured; frames are processed in
memory and are never saved or uploaded. Keep the meeting window and your own
tile visible. Your Zoom display name must match `local_speaker_name` or the
optional `zoom_local_speaker_name` override. If Quill cannot identify your tile,
it withholds Zoom names. The menu shows missing permission or name-match issues.
Set `zoom_visual_speaker_detection` to `false` to disable window capture.

Zoom capture and border/name mapping have passed a synthetic window test;
remote speaking-border detection in a live Zoom call still needs validation.
Web Teams and web Zoom do not yet have dedicated tile adapters. A call with
several remote participants also needs live validation.

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
  "zoom_visual_speaker_detection": true,
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

Repair speaker labels from cached ElevenLabs word timestamps and recorded UI
evidence, without uploading audio or running transcript cleanup:

```sh
quill speakers refresh /path/to/recording --output /tmp/speaker-label-preview
quill speakers refresh /path/to/recording
```

The default reuses the saved acoustic analysis. Add `--remote-speakers 3` to
rerun local speaker separation with a known count; compare a preview first,
because forcing a count can merge voices. In-place refresh keeps exact backups
and rejects edited wording or manual speaker corrections. The microphone
segments stay unchanged, and remote word timestamps come from the original
cache. Run your archive sync afterward to publish the repair.
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

Use **Quill menu > Transcription engine** to choose **Parakeet v3 (local)**
or **ElevenLabs Scribe v2 (cloud)**. The choice is saved and applies to the next
transcription job, including pending recordings. Both tracks of a running job
use the same engine. There is no silent engine fallback.

Set or change your ElevenLabs key from **Quill menu > ElevenLabs API key...**.
The entry field shows the key so you can check it before saving. The key is stored encrypted in **macOS Keychain**,
separately from configuration, recordings, and the app bundle. The app reads it
only when transcription needs it; it is never written to logs or JSON config.
The key is not synchronized through iCloud. The menu also supports removing it.
Quill uses the login Keychain's normal macOS access control.

ElevenLabs uses `scribe_v2`, automatic language detection, and word timestamps.
It uploads each track separately after converting it to 16 kHz mono WAV.
Speaker separation and name attribution then run locally, followed by the
selected transcript cleanup mode and finally the archive hook. Standard
ElevenLabs account billing and request retention settings apply.

API failures leave the session pending. Successful responses are saved as
`elevenlabs-mic.caf.json` and `elevenlabs-system.caf.json` alongside the recording,
keyed by the original audio checksum and model. This lets a resumed session
reuse a completed track without uploading it again. No key is included in
those caches. A network failure after the service accepted a request can still
require a billed retry; the API does not provide exactly-once delivery here.

```bash
quill transcription status
quill transcription key set                  # hidden terminal prompt
quill transcription key set --stdin          # key supplied through stdin
quill transcription configure --engine elevenlabs
quill transcription configure --engine parakeet
quill transcription key remove
quill transcribe ~/Recordings/SESSION --engine elevenlabs --output /tmp/scribe-preview
```

Never pass an API key as a command-line argument. The per-run `--engine` option
does not change the saved selection. Standalone `transcribe` runs neither
cleanup nor archive publication; use `quill postprocess run` to test cleanup
on its output. Completed automatic recordings already follow that sequence.
`--offline` rejects ElevenLabs before any upload and requires cached models
with Parakeet. A missing key leaves recording and the settings menu available.

Whisper has been removed from the app and build. Existing `whisper_cpp` settings
resolve to local Parakeet until another engine is selected; upgrading never
silently enables cloud uploads. Historical transcripts keep their provenance.

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
- `transcription.engine`: `parakeet` (local default) or `elevenlabs` (uploads audio); also selectable from the menu.
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
- Both current engines recognize English and Romanian automatically. Transcript
  cleanup can correct wording, but still requires review for names and ambiguous speech.
- The app bundle provides Quill's identity and permission descriptions. Local
  ad-hoc-signed rebuilds may require refreshing Quill's Accessibility entry.

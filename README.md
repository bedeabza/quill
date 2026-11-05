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

macOS ties Accessibility and Screen Recording grants to the app's code
signature. To keep them across rebuilds, create a local signing identity once:

```sh
python3 tools/package-app.py --create-signing-identity
```

This creates a self-signed code-signing identity, **Quill Local Signing**, in
the login keychain (`--keychain PATH` chooses another keychain). Later
`package-app.py` runs reuse it automatically when neither `--signing-identity`
nor `QUILL_SIGNING_IDENTITY` is set, so the app's designated requirement
(identifier plus certificate leaf) stays the same across rebuilds. macOS may ask
once for your login password when codesign first uses the key; choose
**Always Allow**. The first build signed with this identity needs Accessibility
and Screen Recording granted once more; removing old Quill entries from System
Settings first is advised.

Without that identity, packaging signs ad hoc, whose identity changes when the
executable changes, and warns that rebuilds lose macOS permissions.

To sign with a Developer ID certificate instead:

```sh
python3 tools/package-app.py --signing-identity "Developer ID Application: Your Name (TEAMID)"
```

`QUILL_SIGNING_IDENTITY` sets the same option for repeated builds.

Move `.build/Quill.app` to `~/Applications` using Finder. Quit an older copy
before replacing it. Quill keeps recordings and configuration outside the app,
so replacing the app preserves both.

`sh tools/deploy-app.sh` does all of this in one step: it builds and packages
Quill, quits the running copy (never while it records), replaces
`~/Applications/Quill.app`, reopens it and checks that it keeps running.

To keep the terminal command and start Quill at login:

```sh
python3 tools/install-cli.py
"$HOME/Applications/Quill.app/Contents/MacOS/quill" install --launch-at-login
```

Open Quill once and allow Notifications and Microphone when macOS asks. Enable
**Quill** under Privacy & Security > Accessibility for meeting detection. System
audio permission is requested on the first recording. **Quill → Permissions**
shows what is still missing. Only one recording app
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
2. **Click the feather in the menu bar → Start Recording** (⌘R). First use
   prompts for microphone and System Audio Recording permissions. While
   recording, the icon turns red with a running elapsed counter, and macOS shows
   the purple recording indicator.
3. **Click → Stop Recording** when the meeting ends. Transcription starts
   automatically (the menu shows progress); a notification fires when the
   transcript is ready.

The menu stays short. It shows a status line (**Idle** or
**● Recording · 12:34**) and, while something is transcribing, a line such as
**Transcribing <folder> · 1 queued**. Below are **Start/Stop Recording** (⌘R),
**Keep Recording After Meeting Ends** (only while recording), the meeting
detection status, the **Automatic Meeting Recording** toggle, **Open Quill…**
(⌘O) and **Quit Quill** (⌘Q). When a permission is missing, **Allow meeting
detection…** or **Allow Zoom speaker names…** opens the Quill window at
**Permissions**.

**Open Quill…** opens the Quill window. Its sidebar lists **Recordings**, then
a Settings group: **Transcription**, **Meetings**, **Permissions** and
**General**. **Transcription** holds the default engine and ElevenLabs API key
(see [Transcription](#transcription)), transcript cleanup (see
[Optional transcript cleanup](#optional-transcript-cleanup)) and meeting titles.
**Meetings** holds the automatic meeting recording toggle with its live status,
an explanation of **Keep Recording After Meeting Ends** (a one-off action in the
menu while recording), and **Remember speaker voices**. **General** shows the recordings folder with **Show in
Finder**, the configuration file with **Open** (or **Show Folder** before the
file exists), the version, and **Quit Quill**.

**Recordings** lists recording folders newest first, grouped by day: **Today**,
**Yesterday**, then dates; days from another year show the year. Toolbar search
matches generated and original meeting titles, folder names and participants.
Each row shows the title, time, duration and participants. A tag marks
recordings that are **Transcribing**, **Queued**, **Failed**, **Not
transcribed** or **Unfinished**; ready recordings have no tag. Queued, transcribing and failed
messages appear in a banner.

Selecting a recording shows its title with **Generate Title** or **Refresh
Title**, date and time, participants, and the transcript as speaker turns with
timestamps. The **Original / With names** switch appears for transcribed
recordings and is disabled unless a verified named transcript exists; when one
exists, selecting the recording opens on **With names**; switching to
**Original** lasts until another recording is selected. **Show in Finder** in the toolbar opens the recording
folder. The folder menu in the footer browses another recordings folder and
returns to the default one.

Titles are generated from meeting content for recordings visible in the list
and saved separately in `recording-title.json`; original transcript
headers/text remain unchanged. **Meeting titles** in **Quill → Transcription**
selects **Local titles**, **Automatic AI**, **Codex** or **Claude Code**. Local
titles are the default. Only AI modes send transcript text: bounded excerpts
from the beginning, middle and end go to an already configured, signed-in text
service, with a simple local keyword title if it is unavailable. Each visible
meeting gets a local title before the independent AI queue starts, so titling
does not block transcription. A matching content checksum reuses an existing
title, even after transcript metadata changes. **Generate Title** and
**Refresh Title** request a title without uploading audio or retranscribing the
meeting. Original meeting titles remain searchable.

**Quill → Permissions** checks Microphone, Accessibility (meeting detection),
Screen Recording (Zoom speaker indicators), System audio, the Recordings folder,
Transcription readiness for the default engine, and Notifications. A row shows a
button only when there is something to do, and **Check Again** refreshes the
checks. The sidebar badge counts the items that need attention. Missing capture
permissions leave the app and window available; they do not block browsing or
transcription of existing audio. A refresh does not record, upload anything, or
prompt for anything. System audio tap permission cannot be verified until
recording; make a short test recording and check `system.caf`. A saved
ElevenLabs key does not prove account quota or speech-to-text permission;
those are confirmed by the transcription response.

To regenerate a transcript, select the recording and choose **Regenerate…** in
the toolbar. The sheet selects the engine for this run only; the default for
new recordings does not change. With ElevenLabs, matching saved responses are
reused unless **Request a new ElevenLabs transcript** is checked; a new request
uploads audio again and may be billed again. The sheet states that one aligned
recording with echo reduction is sent to ElevenLabs, and that previous
transcripts are backed up before regeneration. The usual Scribe diarization and
95% name mapping rules apply.

Manual regeneration uses the app's serial transcription queue, even when
automatic transcription is disabled. A recording cannot be queued twice; active
or unfinished recordings cannot be regenerated. Previous outputs and saved
responses are copied to a `transcription-backup-…` folder inside the recording.
If audio preparation or transcription fails, the previous transcript and
prepared-audio files are restored. Original captures are never replaced; a
completed combined cloud response stays cached for retry. The regeneration
does not run automatic cleanup or the archive hook.
Processing shares a lock with the CLI, speaker-label and speaker-refresh
commands so they cannot replace the same transcript concurrently.

Each session lands in `~/Recordings/<yyyy.MM.dd-HHmm>/`:

| File | Contents |
|---|---|
| `mic.caf` | your side (default input device, AAC) |
| `system.caf` | everything the Mac played — the other side of the call (AAC) |
| `meta.json` | start/end timestamps, duration, per-track start offsets |
| `transcript.json` | canonical transcript — engine provenance + timed, speaker-tagged segments |
| `transcript.md` | the same transcript rendered for reading |
| `meeting-audio.wav` | ElevenLabs only: one aligned 16 kHz mono recording, with playback-reference echo reduction before mixing |
| `meeting-audio.json` | preparation version, original checksums/offsets, combined checksum, duration, energy diagnostics and conservative source windows |
| `elevenlabs-meeting-audio.wav.json` | cached Scribe response for the combined recording |
| `transcript-named.json`, `transcript-named.md` | ElevenLabs only: a separate named copy, created only when every combined speaker passes the 95% timeline agreement threshold |
| `speaker-mapping.json` | ElevenLabs only: per-speaker agreement, observed speech coverage, ambiguity and acceptance decision |
| `transcribe.log` | transcription progress/errors for this session |

Two original tracks keep your microphone separate from remote audio. Parakeet
transcribes tracks separately and performs local speaker separation. ElevenLabs
receives one prepared meeting recording and supplies one set of speaker IDs.
CAF needs no finalization pass, so audio already written
remains readable if the process exits unexpectedly.

## Optional transcript cleanup

This applies to local-engine transcripts. ElevenLabs originals and their
optional timeline-named copies are preserved without automatic cleanup.

**Transcript cleanup** in **Quill → Transcription** offers **Off** (the default),
**Automatic**, **Codex (ChatGPT account)**, and **Claude Code**. It processes new
completed recordings before the archive hook runs. The existing transcription
and archive flow continues when cleanup is off, no compatible signed-in CLI is
available, a provider fails, output fails validation, or the run times out.

This uses the installed `codex` or `claude` command-line harness and its saved
sign-in. Quill also checks a compatible CLI bundled with ChatGPT/Codex desktop
when available; installing a desktop app alone does not guarantee a ready
helper. Incomplete standalone helpers are skipped in favor of another ready
installation of the same provider.
Automatic prefers a compatible signed-in harness associated with an open app;
Codex wins a tie. Otherwise it checks Codex, then Claude Code. An explicit choice
never falls back to the other provider, and a failed model request is not resent
to another provider. Quill never installs a harness or prompts you to sign in.

Enabling this option sends transcript text, speaker labels, recorded participants, and any configured
glossary to the selected harness's cloud provider and uses that account's limits.
It is not local model inference. New runs use the setting in effect after local
transcription finishes; changing the setting does not retract a request already
sent. The CLI's normal default model is used. No additional API key is required.

Text corrections preserve segment boundaries, timestamps, numeric values, and
explicit English/Romanian negations. Invalid proposals are skipped individually.
These checks reduce unwanted rewriting but cannot prove every correction is accurate.
Speaker corrections backed by a verified sole-remote-participant interval or an
explicit user confirmation can update anonymous or inconsistent names automatically.
Manual names remain protected. Unsupported text-only speaker suggestions stay in
the report for review, and a multi-person roster alone cannot establish who spoke.

A successful edit keeps exact originals under `postprocess-backup-<id>/`, updates
`transcript.json` and `transcript.md`, and records edits, speaker suggestions,
provider, and input/output hashes in `postprocess.json`. Repeating a successful
run on the same transcript skips it. The one-off command does not run the archive
hook. Existing recordings are not automatically submitted when cleanup is enabled.

Each proposed correction is checked independently. Valid corrections are applied;
rejected edits leave their original segment unchanged and are listed with a reason
in `postprocess.json`. Rejected speaker suggestions are listed by proposal index.
Conflicting edits for the same segment are all rejected. The edit-size limit guards
against substantial rewrites by a model without audio; it does not stop recording,
transcription, or other valid cleanup edits.

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

Quill saves a participant roster in `participants.json` while recording and keeps
membership observations in `speaker-observations.jsonl`. Names are collected from
meeting tiles independently of their speaking indicators. The scoped meeting tree
is refreshed during the call, including background browser tabs, so silent people,
late arrivals, and departures can be recorded. Known names survive missing UI data.
Clock-like text such as a call timer (`--:--`, `54:11`, `01:07:30`) is never a name,
and Teams' call control bar never contributes participant names. Older
recordings that saved Teams timer ticks as participants are shown without them;
their `participants.json` is not rewritten.
The transcript and archive list participants before the spoken transcript, and the
coding harness receives that roster plus verified speaker assignments.

A complete participant count and named roster let Quill assign a two-person call's
remote audio to the other participant, including short replies and acoustic
clustering gaps. Unknown membership, blind periods, and multi-person intervals do
not authorize guessing. An explicitly confirmed sole remote speaker covers the
whole recording. Established voice identities no longer require UI evidence for
a fixed fraction of the person's total speaking time as a meeting gets longer.

With Parakeet, speaker separation runs automatically after recording, entirely
on-device, using FluidAudio's offline Pyannote/WeSpeaker/VBx pipeline. Unknown voices
receive stable IDs within that transcript and readable labels such as
`Speaker 1`. Ambiguous overlapping speech remains `Unknown speaker`.

With ElevenLabs, Scribe v2 performs diarization (`diarize=true`). Quill never
runs local diarization or voice-memory matching on that path. `transcript.json`
and `transcript.md` preserve the Scribe text, times and anonymous speakers;
`provider_speaker_id` retains Scribe's original ID from the combined recording.
Readable speaker numbers share one meeting-wide list. Automatic transcript cleanup and
roster-based speaker relabeling do not modify this original.

Quill compares each combined speaker's timed words with recorded active-speaker
UI evidence. A name must account for at least 95% of that speaker's **observed
speech duration**, and **every speaker must pass** before Quill writes
`transcript-named.json` and `transcript-named.md`. No evidence or an unknown
provider speaker fails the check. Time without observations is excluded from
the denominator; `speaker-mapping.json` also reports coverage so that 100%
agreement is not mistaken for 100% observation. Duplicated evidence counts once;
conflicting names and overlapping provider voices count as ambiguity. Caption
text, participant lists and saved voice fingerprints do not vote for names.
The named copy changes names and attribution only, retaining speaker IDs,
wording, segment boundaries and timestamps. For combined audio, a local name
also requires actual local active-speaker evidence; it is never assigned from
the microphone setting alone. Only clear local-only or remote-only audio
windows may support the corresponding UI name. Overlap and uncertain source
windows do not vote. Shared-microphone local tiles cannot establish individual
names. Legacy separate-track recordings retain their original refresh rules.

Both variants include the observed participant roster and, when exposed by the
identified meeting's own window/document/tab, the meeting title. The title is
captured during recording and saved as `meeting_title` in `meta.json` and the
transcripts. Generic app labels, URLs and Meet room codes are not treated as
meeting subjects; unavailable titles remain absent.

For Google Meet, Quill reads each visible speaker tile's name and speaking
indicator through macOS Accessibility. It caches the tile controls during its
regular meeting scan, then reads their state four times per second while
a meeting is present, independently of recording. This works independently of the spoken language and does not
require Meet captions, saved transcripts, or a browser extension.

Recorded speaking tiles provide direct name evidence. Quill can also retain a
name through missing tile samples when that recording's acoustic voice has at
least 10 seconds of consistent UI evidence across multiple turns, sufficient
coverage, and no sustained competing name. Split acoustic clusters may share
the same verified name. Caption text alone never establishes a voice identity.
A mixed acoustic cluster stays unnamed as a whole, but clean windows inside it
can still train a fingerprint when their speaking-tile evidence identifies one
person and the independent voice samples agree.
Conflicting evidence and ambiguous overlapping voices remain unresolved.
Short replies can use a bounded edge of a sustained speaking indicator to
account for UI delay. Words with uncertain evidence keep an anonymous label.
The local tile is excluded from remote naming, and changing tile names invalidate
the cached association until the next scan. Minimized meeting windows cannot
provide tile evidence. The Meet name and activity structure was verified in
Brave; other browsers need live validation.

Teams desktop uses its accessible participant names and speaking-frame state.
This was checked in a two-person call with captions off. Unknown layouts and
explicitly pinned tiles do not contribute names. Your own Teams tile is not read
yet, so a combined Teams recording has no local speaking evidence and does not
get a named copy. Teams also lights a remote person's frame for background sound
on an open microphone; while two frames are lit, that time counts as ambiguous.

Zoom desktop exposes participant names through Accessibility. Quill also needs
Screen Recording permission to read the green/yellow active-speaker borders.
Only the identified Zoom meeting window is captured; frames are processed in
memory and are never saved or uploaded. Keep the meeting window and your own
tile visible. Your Zoom display name must match `local_speaker_name` or the
optional `zoom_local_speaker_name` override. If Quill cannot identify your tile,
it withholds Zoom names. The menu's meeting detection status reports missing
permission or name-match issues; without Screen Recording permission, **Allow
Zoom speaker names…** opens **Quill → Permissions**.
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
  "speaker_voice_memory": true,
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

Use `--offline` to require cached local models. With Parakeet, `--no-speakers`
skips separation and `--remote-speakers 4` supplies a known count. With ElevenLabs,
`--no-speakers` skips name mapping while Scribe still diarizes; `--remote-speakers`
is rejected. `--force` replaces an
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

Re-evaluate the optional named copy from cached ElevenLabs diarization and
recorded UI evidence, without uploading audio, local diarization or cleanup:

```sh
quill speakers refresh /path/to/recording --output /tmp/speaker-label-preview
quill speakers refresh /path/to/recording
```

Refresh preserves the original transcript and keeps exact backups. It rejects
edited wording, manual corrections and `--remote-speakers`; the same 95% gate
controls the separate named copy. A previous named copy is removed when the
new evidence no longer passes. Older caches created with diarization disabled
cannot be refreshed: explicitly regenerate with `quill transcribe RECORDING
--engine elevenlabs --force`, which uploads audio again. Run archive sync
separately if needed; consumers of `transcript.json` receive the pure original.
Speaker tracking belongs to the running app. Fresh participant membership is
available when a recording starts, and a Meet room change inside the same tab
retains the recording while clearing old tile references and refreshing the
roster. Idle discovery collects UI metadata only, not microphone/system audio.
Turning meeting detection off also stops this discovery.

Quill can remember verified remote voices locally for later recordings. It
learns from sustained speaking-tile evidence or an explicit sole-speaker
confirmation. It averages independent, non-overlapping speech samples into
voice fingerprints; captions and predicted names cannot train the store.
Recognition requires at least nine clean speech windows, agreement across
multiple pooled samples, a strong similarity and runner-up margin, and no
conflicting current speaker or participant evidence. Uncertain voices remain
unnamed. Matches appear as `voice_fingerprint` in transcript attribution.

Fingerprints are stored in a private directory at
`~/Library/Application Support/Quill/SpeakerMemory/profiles.json`, with model
versioning and source-audio hashes to prevent duplicate enrollment and matching
a recording against itself. Audio is not uploaded for fingerprinting. Each
person retains at most 24 prototypes. Matching runs during post-call speaker
analysis; this does not add live audio recording outside calls.

Use **Remember speaker voices** in **Quill → Meetings**, or manage memory with:

```sh
quill speakers memory status
quill speakers memory status --enabled false
quill speakers memory status --enabled true
quill speakers memory learn /path/to/recording
quill speakers memory learn /path/to/recording --sole-remote-speaker "Alice"
quill speakers memory forget "Alice"
```

The `learn` command reads local audio and verified UI evidence without changing
existing transcripts. It skips recordings without enough reliable samples.
Transcription previews can use saved fingerprints but never enroll new ones.
Disabling memory preserves the store and stops automatic learning/matching.
Forgetting a person removes their saved fingerprints; it does not rewrite
previous transcripts.

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

With Parakeet, each track is transcribed separately, shifted by its start
offset and merged by timestamp. ElevenLabs uses one aligned meeting recording.
Jobs run in a serial queue — you can
start a new recording while the last one transcribes. Unfinished jobs resume
on next launch (the filesystem is the queue: a session with `meta.json` but no
`transcript.json` is pending). Failures append to the session's
`transcribe.log` and never block later jobs.

To run the on-device English/Romanian regression after the v3 models are
cached, use `sh tools/test-transcription.sh`. It synthesizes disposable speech
with macOS's Samantha and Ioana voices and checks English, Romanian (including
diacritics), and switching back to English on the same engine. The regular
`swift test` suite skips this model-dependent test.

Choose the default engine in **Quill → Transcription**: **Parakeet v3** (on
this Mac) or **ElevenLabs Scribe v2** (in the cloud). The choice is saved and
applies to the next transcription job, including pending recordings. Choosing
ElevenLabs without a saved key is refused with "Save an ElevenLabs API key
first." Both tracks of a running job use the same engine. There is no silent
engine fallback.

Enter your ElevenLabs API key in the same pane; its status reads **Saved** or
**Not set**, with **Save** and **Remove**. Quill stores the key in
`~/Library/Application Support/Quill/elevenlabs-key`, a plain file only your
user account can read (mode 0600, inside a 0700 folder) and excluded from Time
Machine backups. The file is not encrypted: other processes running as your
user can read it, as with most command-line credentials. No system dialog is
shown when saving or reading it. The app, `quill transcription key set`,
`set --stdin`, `remove` and the transcription engine all use this file, which
is separate from configuration, recordings and the app bundle. The key is never
written to logs or JSON config. Quill refuses to read the file if other
accounts can access it or if it is not a regular file, and asks you to save the
key again. `quill transcription status` reports the file path as
`credential_storage`. Startup checks include the key, since reading it never
prompts.

Keys saved by earlier versions in Keychain are not migrated: after updating,
paste the key once in **Quill → Transcription**. The old Keychain item
**Quill: ElevenLabs API key** (service `com.bedeabza.quill.elevenlabs`) is no
longer read; you may delete it in Keychain Access.

ElevenLabs uses `scribe_v2`, automatic language detection, speaker diarization
and word timestamps.
Quill aligns both tracks using their saved start offsets, uses bundled
SpeexDSP echo cancellation to reduce system playback leaking into the mic,
then mixes the cleaned mic and direct system audio at half gain each into
one 16 kHz mono WAV. A recording with just one declared track is aligned
without mixing or echo cancellation. Missing/invalid declared tracks fail
before any upload. The original CAF files remain unchanged.

One combined file is sent in one request, or its matching cached response is
reused. No external audio tools need to be installed. Echo reduction is best
effort: clipping, room acoustics, capture-clock drift and overlapping voices
can still limit accuracy. It does not guarantee the true number of people.
Transcription requests use a five-minute timeout.
Audio preparation and optional timeline-based name mapping run locally. The
selected transcript cleanup mode is skipped to preserve the original. The
archive hook runs after both outputs have been prepared. Standard
ElevenLabs account billing and request retention settings apply.

API failures leave the session pending. Successful responses are saved as
`elevenlabs-meeting-audio.wav.json` alongside the recording, keyed by the
combined audio checksum and model. The preparation manifest also validates
the original checksums, offsets and preparation version. Old per-track
responses remain available for audit and legacy speaker refresh, but are
never combined or reused as a meeting-wide response. Regenerating an old
recording therefore requires a new upload once; **Request a new ElevenLabs
transcript** subsequently invalidates only the combined response. No key is
included in these caches. A network failure after the service accepted a request can still
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
with Parakeet. A missing key leaves recording and the Quill window available.

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
- `transcription.engine`: `parakeet` (local default) or `elevenlabs` (uploads audio); also selectable in **Quill → Transcription**.
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

With **Automatic Meeting Recording** enabled in the menu or in **Quill →
Meetings**, Quill starts detected
meetings automatically and stops 30 seconds after the associated meeting tab or
call window closes. Native macOS notifications announce recording start and stop,
without asking for confirmation. Their appearance and visibility follow macOS
notification preferences and Focus settings. When Accessibility permission is
missing, **Allow meeting detection…** in the menu opens **Quill → Permissions**
to grant it. Turning the toggle off stops an automatically started
recording; manually started recordings remain under manual control. While
recording, the menu also offers **Keep Recording After Meeting Ends**, a
one-off action for that recording. Manually stopping a recording
suppresses automatic restart for that meeting until it ends or the toggle is
turned off and back on.

Detection uses macOS Accessibility, without browser extensions. Brave, Chrome,
Edge, Safari, Firefox, Arc, and other browsers registered to handle web URLs are
inspected for exposed meeting tabs. Desktop Teams, Zoom, and Slack are inspected for
call controls and their meeting windows. Google Meet, web Teams, web Zoom, and Slack
pages can be recognized when the browser exposes the relevant meeting URL.
Background tab labels maintain a previously identified meeting, but cannot
start recording by themselves.

Slack huddles use the same automatic recording toggle in the desktop app and
browser. Detection requires joined huddle controls, such as Leave huddle or
Leave with microphone controls. Opening Slack, browsing chats, or seeing a
Start/Join huddle button does not start recording. A complete, visible return
to Start/Join controls after leaving begins the usual 30-second stop countdown,
even when the Slack window or tab stays open. Browser huddle controls are read
only from their Slack page. Hidden or incomplete reads do not infer an end.

Slack speaker names come from the huddle's participant grid in the desktop app
and browser. Quill samples each peer's speaking indicator, excludes your local
name, and discovers participants as they join, leave, or change their display
name. Keep the huddle grid visible for live speaker attribution. The native
pop-out supplies speaker evidence even when recording was linked to Slack's
main window. Muting, video state, chat profiles, and roster membership alone
never count as speaking. Ambiguous or unavailable indicators leave speech
unnamed rather than assigning it to another participant.

Browser/app versions and accessible labels vary. Closed tabs and windows are
end signals; recognized English-language end screens are also supported. A
hidden control, mute, silence, switching tabs, or a failed Accessibility read
does not authorize stopping. If a browser hides its tab information, or an app
keeps the window open without an identifiable end screen, Quill continues
recording and reports that meeting status is unavailable. Manual stopping stays
available. Calls in other UI languages need matching accessible labels.

The feature is on by default and can be disabled in the menu, in
**Quill → Meetings**, or with
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
- **NSStatusItem** — the menu-bar menu, which opens the single Quill window

## Gotchas

- A global tap records *everything* the Mac plays — notification dings,
  music, all of it. Don't play Spotify during meetings (or ask for a
  per-process picker if it bothers you).
- If recordings come out silent, check System Settings → Privacy & Security →
  Screen & System Audio Recording.
- Both current engines recognize English and Romanian automatically. Transcript
  cleanup can correct wording, but still requires review for names and ambiguous speech.
- The app bundle provides Quill's identity and permission descriptions. Ad hoc
  signed rebuilds lose the Accessibility and Screen Recording grants; create the
  local signing identity once (see Install) to keep them.
- SwiftPM normally records the deployment target (15.0) as the SDK version,
  which draws the macOS 15 look. `Package.swift` passes
  `-platform_version macos 15.0 26.0` to the linker, so binaries record SDK 26
  (the current macOS look) while still requiring only macOS 15
  (`otool -l` shows minos 15.0, sdk 26.0).

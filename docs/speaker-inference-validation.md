# Speaker inference and manual speaker names

## Behaviour

ElevenLabs recordings keep the evidence gate: a name backed by speaking-tile
evidence needs 95% agreement over at least 25% of the voice's speech. Voices the
gate leaves unnamed on the combined recording can now be named by two
inferences (`ElevenLabsTranscripts.infer`), in this order:

1. `local_microphone_majority`: exactly one voice has at least 90% of its
   single-source audio in microphone-only windows, at least 5 seconds and 25% of
   its speech; no other voice is at least 50% microphone-only. It gets
   `local_speaker_name`. Not with a shared microphone or without a local name.
2. `roster_elimination`: the Scribe voices and the distinct roster names (you
   included) are equal in number, every assigned name is in the roster, and
   exactly one voice and one name remain. That voice gets that name.

Evidence-backed names are never replaced. Substantial evidence for someone else
(at least 50% agreement over 25% coverage) blocks either inference, as does
another voice already named as you. Each name records how it was found in the
named copy's `attribution` and in `speaker-mapping.json` (`name`, `attribution`,
`local_seconds`, `remote_seconds`; `accepted` still means the evidence gate). The
named copy is written when every voice has a name. `--no-speakers` disables the
inferences. Separate-track recordings are unchanged.

The Recordings window shows a **Speakers** block when an ElevenLabs recording has
no named copy or its named copy leaves a voice unnamed: "Speaker N is [name]" per
voice, listing the recording's participants and **Unknown**, with the reason for
each pre-selection. Defaults come from the assigned names, then the strongest
remaining tile evidence, then the voice that is mostly your microphone, then the
only participant left; no name is pre-selected twice. Reports written before this
change get their microphone seconds from the saved `speaker-analysis.json` and
`meeting-audio.json`, for defaults only. **Apply Names** (`SpeakerNames.apply`)
writes `transcript-named.json`/`.md` under the recording lock with `manual`
attribution and backs up a replaced named copy to `speaker-label-backup-<id>/`;
`transcript.json` is never edited. **Name Speakers…** in the actions menu reopens
the block for a complete named copy. `quill speakers label <dir> --speaker
meeting_1 --name NAME` does the same for one voice.

## Why the Teams call at 17:04 had no tile evidence

`2026.11.05-1704` (and `2026.11.05-1544`, the earlier call with the same person)
are Teams desktop direct calls, titled with the other person's name. Neither has a
single `meeting_tile` observation, against 6395 in the 10:48 Teams meeting. The
roster found the remote name in every scan (174 and 573), and the roster and the
tile adapter read the same complete snapshot, so a `vdi-occlusion` name container
without a toolbar existed; what failed is one of the other structural checks in
`TeamsTileEvidence.tiles` (an `AXMenuItem` tile with `Context menu is available`,
not pinned, one name container and one direct frame overlay). It is not a
regression: the tile adapter and the speaker scanner did not change between the
10:48 and 17:04 recordings (`git diff 7d028de~1 HEAD -- Sources/quill/Meetings`
touches only the roster), and #3461's toolbar rule applies to the roster only. A
2-person *meeting* (Helen, 13:41) matched; its tile was detected camera on and off.
No Accessibility tree of a direct call is on disk, so the layout is still unknown.
The capture needed: during a Teams desktop direct 1:1 call, with the other person
talking for about 20 seconds then silent for 10, run
`~/Applications/Quill.app/Contents/MacOS/quill meetings --speakers --speaker-boxes --watch > /tmp/teams-direct.jsonl`
and note whether their camera was on and whether the window was the full call
window.

## Validation

Read-only previews, `quill speakers refresh ~/Recordings/<dir> --output
/tmp/quill-preview/<dir>` (cached Scribe diarization, no uploads; the recordings'
files were not modified):

| Recording | Before | Automatic names now | Pickers default to |
| --- | --- | --- | --- |
| 2026.11.05-1704 (Teams direct call) | no named copy | named: Speaker 1 Dragos Badea (`local_microphone_majority`, 118.0 s mic-only vs 0.4 s remote), Speaker 2 Patranca, Bogdan - CTP (`roster_elimination`) | same, "Mostly your microphone", "Only participant left" |
| 2026.11.05-1544 (Teams direct call) | no named copy | named the same way (194.5 vs 1.2 s; 3.2 vs 155.6 s) | same |
| 2026.11.05-1048 (Teams, three people) | no named copy | Speaker 2 Dragos Badea (`local_microphone_majority`, 257.6 vs 2.1 s); two remote voices and two names remain, so no named copy | Speaker 1 Patranca, Bogdan - CTP (tile, 87%), Speaker 2 Dragos Badea, Speaker 3 Marian (tile, 24%) |
| 2026.11.05-1341 (Teams, Helen) | no named copy | named: Speaker 1 Dragos Badea (`local_microphone_majority`, 6.6 s), Speaker 2 Helen (evidence, 100% over 39%) | same |
| 2026.11.05-1025, 1121 (Meet) | named | unchanged, evidence only | (block hidden) |

`2026.11.05-1346`, cited in the coverage-floor regression, is no longer in
`~/Recordings`. The turns read consistently with the names: in 1048, Speaker 1
opens with "Salut, Dragoș" and Speaker 2 answers "Salut, Bogdan", matching its
pickers.

Tests: `ElevenLabsTranscriptsTests` covers the two-person inference with its
labels, a second mostly-microphone voice, an unclear majority, more names than
voices, more voices than names, and contradicting versus agreeing sub-gate
evidence; `SpeakerNamesTests` covers the defaults (never the same name twice, no
guess with two names left) and Apply (manual named copy, backup of a replaced
copy, original byte-identical, unknown speaker refused). `swift test`: 241 tests,
11 skipped, 0 failures. The CLI path was run once on a copy in `/tmp`: two
`speakers label --speaker` calls built the named copy with a backup, the original
was unchanged, `--sole-remote-speaker` was refused, and `speakers refresh` then
refused to overwrite the manual names.

The deployed app showed the block on 1704 and 1048 in the real window; a picker
opened with the participants and Unknown and was cancelled with Escape (no files
written). Apply Names was exercised on a copy of 1704 browsed from
`/tmp/quill-gui`: the named copy appeared, the block hid, and **Name Speakers…**
reopened it with "Chosen by you" and Cancel. The window was returned to the
default folder.

Still to validate live: a new Teams direct call transcribed end to end, a call
with someone in the room on the same microphone, and the Teams direct-call tile
layout above.

# Speaker names validation

## Slack huddle speaker detection, 2026-09-15

The native Slack test huddle exposed participants as `AXCell` elements with
`p-huddle_peer_tile` under `p-huddle_grid_component`. Each cell's accessible
description was `View <name>'s profile`. Two live snapshots captured the
`p-huddle_peer_tile__mic_overlay` / `p-huddle_peer_tile__overlay--active_speaker`
marker moving from the remote participant to the local participant.

The adapter caches the peer cell and samples its bounded subtree every 250 ms,
because Slack inserts and removes the overlay. It validates the peer name
before and after each sample, excludes the configured local name, and refuses
unknown layouts, duplicate names, nested peers, failed reads, and slow or oversized
subtrees. Native Slack's unique joined peer-grid window supplies speaker data
when the recording was linked to its main chat window. Browser discovery remains
scoped to the linked meeting document.

The rebuilt diagnostic produced five consecutive samples naming the remote
participant and persisted both roster names in diagnostic observations for both
native window identities, without restarting the running recorder. Nine new tests
cover the captured transitions, browser document scoping, exact profile labels,
self/roster handling, mute and pin controls, renames, duplicate names, and read
failures. The full suite passed 138 tests, with 9 optional tests skipped.
A live browser huddle and a call with several remote participants remain untested.
No complete participant count was exposed, so the Slack roster does not authorize
sole-speaker inference during missing activity observations.

## Continuous speaker discovery update, 2026-09-10

A completed 28-minute call retained tile observations only between 26 and 85 seconds. The saved observations cannot establish the exact UI failure or identify the later unnamed speech. No historical transcript was relabelled.

Speaker discovery now runs throughout the meeting, starting another pass two seconds after the previous pass finishes. It walks only the linked meeting document or native call window, in bounded chunks between activity samples. Large trees continue across polls instead of restarting at the old 1.5-second or 2,500-node limit. A complete pass replaces the cached names and removes departed participants. Destroyed elements, changed names, and unrecognized activity markup invalidate the cache and trigger rediscovery. Stale, incomplete, or failed discovery does not authorize a name.

Meet name matching accepts additional wrappers within an individual tile but cannot cross into a container shared with another speaker indicator. The configured local display name is also excluded from remote tile attribution. Caption matching and explicit active-speaker evidence remain available; names still apply only to supported speech intervals, never every turn in an acoustic cluster.

Validation: 61 Swift tests, 56 passed, 5 opt-in audio or window-capture tests skipped. This includes replay of the previously captured Meet and Teams activity states, plus 11 new regressions for late arrivals, renames, departures, large trees, chunk time limits, stale and destroyed elements, changed meeting documents, wrapped tiles, local-name exclusion, and avoiding retrospective name propagation. A real multi-person call with a late join remains to be verified.

The release was packaged, signed, installed, and verified against the signed staging app. After renewing the existing macOS Accessibility entry, the running LaunchAgent resumed automatic recording and captured sustained named Teams tile observations in the live call. No recording was interrupted. The previous app is backed up at `/private/tmp/quill-speaker-refresh/Previous-Quill.app`.

Validated on 2026-09-09 on the user's Apple Silicon Mac.

- Full Swift suite: 33 tests, 32 passed and the opt-in language test skipped.
- Separate real Parakeet language test: English, Romanian, English passed.
- Real offline diarization: automatic counts of 1, 2, 3, and 4 on the control fixtures.
- Complete three-voice English test: local synthetic voices, independently supplied caption labels, ASR, diarization, timed name assignment, JSON/Markdown output, and archive import. All three names survived and every named segment remained inside that person's actual speech interval.
- Live Brave Google Meet: read the user's self-caption and sentence fragments through Accessibility, including with another Brave window foreground. The captured `You` label is excluded from remote naming.
- Manual correction: all turns of the chosen speaker changed, other speakers remained identical, and an exact JSON backup was retained.
- Archive suite: 16 tests passed, including legacy rendering and v2 names/source separation.
- Completed an offline preview of the user's 79-minute recording without changing its original files or invoking its publication hook.

The initial FluidAudio clustering prior merged some short voices. A 0.2 prior passed the one- through four-voice controls. These are regression samples, not a claim of perfect speaker counts on arbitrary recordings.

The complete pipeline test exposed a more serious name-propagation issue: one acoustic cluster can contain speech from different people. Names now apply only to the words matched to captions or locally supported activity intervals. A regression explicitly verifies that two people merged into one acoustic cluster keep separate names and that an unmatched second person's speech stays unnamed.

Voice recognition across meetings was tested on different utterances and was not reliable enough to ship. No persistent voice profiles or automatic voice-memory matching are included.

## Tile naming update

The user's Romanian two-person call exposed the caption dependency: Meet captured the correct participant name while producing garbled English captions. The existing transcript's 26 remote segments were corrected from the verified name and the user's confirmation of the sole remote person, with an exact backup retained. Publication to the existing archive was explicitly approved and verified.

The primary Meet adapter now reads speaker boxes. Live Brave snapshots captured both names and changing tile classes with captions off. The meaning of the activity class was verified by reading Meet's loaded stylesheet locally: it controls speaker-border animation and the visibility of the speaking indicator. Quill caches the matching name/indicator elements and polls them every 250 ms; the full meeting scan stays at two seconds. Missing, conflicting, stale, and single-frame states do not create name spans.

Added regressions cover two tile names, exclusion of the local tile, changed/unrecognized markup, language-independent names, two names sharing one acoustic cluster, lost samples, simultaneous speakers, and bounded repair of clipped diarization edges. Captions are optional and automatic enabling now defaults off.

## Teams and Zoom desktop update

Live Teams 26213.1006.5011.1671 exposed Daria's name under `vdi-occlusion` and a separate frame overlay that gained `vdi-frame-occlusion` during speaking and lost it afterward. The adapter uses that state, excludes self and explicitly pinned tiles, and rejects ambiguous structures. Tests replay the captured on/off states. Focus, pinning transitions, other layouts, and calls with several remote people still need live validation.

Live Zoom 7.0.6 (84834) exposed both participant names and audio mute state, but no reliable accessible active-speaker property. Native meeting detection now also recognizes joined-audio video renderers when the toolbar is hidden. With the user's explicit approval, the new adapter captures only the identified Zoom meeting window using ScreenCaptureKit. Images are processed transiently and never saved or uploaded. It matches green/yellow borders to the accessible tile frames, excludes self and muted participants, and discards ambiguous names, changed frames, slow captures, and off-screen windows. The user's own tile must be visible and match the configured display name.

The live Zoom window was successfully captured, but the remote participant had left before the visual reader was ready. Positive remote speaking-border detection in a real Zoom call remains unverified. A real ScreenCaptureKit test against a temporary synthetic window passed border-to-name coordinate mapping and mute exclusion. Pixel tests cover green/yellow outlines, blue focus outlines, solid green backgrounds, incomplete borders, image orientation, and the shared timed-name pipeline.

Final platform suite: 50 tests, 49 passed and the separate opt-in language test skipped. This run included captured Meet/Teams states, the one- through four-speaker controls, and the synthetic capture window on the secondary display with self-identification and mute checks. Transcription models were unchanged by this update.

Teams and Zoom desktop naming requires Accessibility. Zoom visual naming additionally requires Screen Recording permission; `zoom_visual_speaker_detection: false` disables capture, and `zoom_local_speaker_name` can override the local display-name match. Web Teams, web Zoom, other browser variants, and a live call with several remote people still need validation. The app remains ad-hoc signed, so macOS may require refreshing permissions after an update.

Public audio fixtures: [meeting-transcriber fixtures](https://github.com/pasrom/meeting-transcriber/tree/main/app/MeetingTranscriber/Tests/Fixtures). The four-speaker sample is AMI ES2004a Mix-Headset, 948.019 to 1041.810 seconds, CC BY 4.0. Synthetic English fixtures are generated by `tools/test-speaker-names.py` using macOS voices.

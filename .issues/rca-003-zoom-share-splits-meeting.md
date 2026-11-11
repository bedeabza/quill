---
title: "Zoom screen sharing splits a meeting into several recordings"
date: 2026-11-11
status: done
affects: "meeting detection, automatic recording"
---

## Context

One Zoom call on 2026-11-11 became three recordings (2026.11.11-1401, -1409,
-1419). About 2.5 minutes were not recorded at each split.

## Evidence

See `docs/zoom-screen-sharing-validation.md`, "Incident": each recording
stopped 30 s after the Zoom meeting window disappeared, at the moments Dragos
shared his screen; the window stayed absent for the whole share (no video-tile
reads in the unified log), and Quill started a new recording when it returned.
Zoom held its call audio throughout and released it within 4 s of the real end.

## Root cause

`MeetingScanner` treats a closed native call window as a positive end signal
unless another window of the app shows call controls. While sharing, Zoom hides
its meeting window and shows only share windows, which have no Leave/End plus
Mute controls and no "Zoom Meeting" title, so the meeting read as ended.

## Fix

For an established Zoom meeting whose window is gone: Zoom share windows keep
it present; Zoom still running audio makes the read uncertain (recording
continues); a returning call window rebinds to the same meeting ID. An
automatically stopped meeting that reappears starts again on the next poll.

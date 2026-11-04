# Permissions and readiness checker

The Quill menu exposes **Permissions & readiness…**; the recordings browser
exposes **Permissions…** with the selected folder, recording and engine.
Checks refresh every three seconds while open. Filesystem and Keychain work
run away from AppKit. A blocked credential operation is shown as waiting;
opening the checker never initiates Keychain authorization, capture or uploads.
Startup capture/folder failures remain visible in diagnostics but no longer
exit the menu app, leaving the checker and existing-recording browser usable.
The `doctor` CLI still returns failure for hard errors.

Checks cover microphone authorization, Accessibility for meeting detection,
screen capture for Zoom speaker indicators, notification authorization and
banners, actual folder listing/write/read/rename/delete operations, selected
recording metadata/audio readability, and local model or ElevenLabs credential
availability. Probe files are temporary and original files are not changed.

Screen access does not imply Core Audio tap access. The latter remains
explicitly unverified until recording is tested. Readable credentials do not
prove ElevenLabs quota or speech-to-text entitlement; server responses remain
the source of truth for those. **Authorize key** is an explicit user action
which may open a macOS Keychain dialog; passive checks disable interaction and
restore its prior process-wide setting on the existing serialized queue.

## Validation

- Debug and release builds using the local Swift toolchain.
- Standalone regression runner against production objects, using the existing
  XCTest test bodies plus `PermissionsReportTests`: 56 scenarios. The host has
  Command Line Tools without XCTest, so `swift test` is not available.
- Added cases cover dialog suppression and restoration, explicit authorization
  without accessible metadata, missing/locked/invalid/cancelled credentials,
  cleanup and preservation of existing folder contents, missing folders/audio,
  and truthful local versus remote credential readiness.
- Offscreen AppKit checks cover all eight rows, asynchronous checks, synthetic
  credential authorization, reachable controls on a 520-point viewport, and
  browser search/preview/layout at 1040 and 860 points.
- No user audio was uploaded or recorded for these checks, and no real saved
  API key was read by the regression/UI fixtures.

## Queue investigation on this computer

The installed binary matched the previously delivered build. Existing recording
logs showed serial processing followed by successful regeneration completion,
including the October 30 and October 14 recordings. The live process sample
showed an idle AppKit event loop, rather than a blocked Keychain call. A queued
recording now names the active recording it is waiting behind, making this
normal queue behavior visible.
